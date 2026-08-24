// Cogplomacy shared renderer + drivers.
//
// One canvas scene — the 1901 map of Europe as the stage. Provinces are
// drawn from data/map1901.json (a committed vector map: one polygon, one
// label anchor and one supply-centre dot per province, in a 1000x800 space),
// tinted toward the owning power's seat colour; supply centres are amber
// stars, filled when owned and hollow when neutral. Armies are seat-coloured
// blocks carrying the power's initial, fleets are seat-coloured pennants.
// During press, letters fly between capitals; at adjudication every order
// draws at once — moves as arrows, supports as glowing braces, convoys as
// dashed sea paths — bounces flash, dislodged units go grey, and a unit that
// moved against a pledge made that turn gets a red STAB stamp.
//
// Fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle). All
// state derivation happens server-side / wasm-side; this file only draws
// state objects:
//   {seats:[{power,name,centres,units,score,pending,eliminated,
//            stabbedThisTurn,broadcast,lettersOut,pledges,notes} x7 by SEAT],
//    seatOfPower[7], units[], owners[34], arrows[], stabs[], standoffs[],
//    year, season, phase, years, yearsPlayed, counts[][], press[],
//    gameDone, reason, soloist}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Seven
  // seats need seven colours; the map is coloured by SEAT, so a seat keeps
  // its colour across episodes whatever power it drew.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange",
    "violet2"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a",
    violet2: "#c9a0f0"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var SEA = "#3d6289";
  var SEA_DEEP = "#345477";
  var LAND = "#e6dac2";
  var LAND_DIM = "#cfc0a4";
  var POWERS = ["AUSTRIA", "ENGLAND", "FRANCE", "GERMANY", "ITALY", "RUSSIA",
    "TURKEY"];
  var POWER_SPRITE = ["cog_austria.png", "cog_england.png", "cog_france.png",
    "cog_germany.png", "cog_italy.png", "cog_russia.png", "cog_turkey.png"];
  var TOTAL_CENTRES = 34;
  var SOLO_CENTRES = 18;
  var MAP_URL = "map1901.json";
  var MAP_TIMEOUT_MS = 8000;
  // Timing of the phase transitions.
  var ARROW_MS = 900;
  var LETTER_MS = 1400;
  var STAMP_MS = 1600;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    if (!pending) { done(images); return; }
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  // The map is data, not code, so it is fetched — but the viewer must never
  // hang on it: a bounded fetch that fails still draws (a schematic grid),
  // which keeps `data-replay-loaded` honest.
  function loadMap(base, done) {
    var settled = false;
    function finish(map) {
      if (settled) return;
      settled = true;
      done(map);
    }
    window.setTimeout(function () { finish(null); }, MAP_TIMEOUT_MS);
    try {
      fetch(assetUrl(base, MAP_URL))
        .then(function (response) {
          if (!response.ok) throw new Error("map " + response.status);
          return response.json();
        })
        .then(function (map) { finish(map); })
        .catch(function () { finish(null); });
    } catch (ignore) {
      finish(null);
    }
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = POWER_SPRITE.concat(["arena_floor.png"]);
    loadImages(assetBase, names, function (images) {
      loadMap(assetBase, function (map) {
        diploLearnProvinces(map);
        onReady({
          draw: function (view) { draw(ctx, canvas, images, map, view); },
          map: map
        });
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }
  function mix(hexA, hexB, t) {
    var a = hexToRgb(hexA);
    var b = hexToRgb(hexB);
    return "rgb(" + Math.round(a[0] + (b[0] - a[0]) * t) + "," +
      Math.round(a[1] + (b[1] - a[1]) * t) + "," +
      Math.round(a[2] + (b[2] - a[2]) * t) + ")";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function seasonLabel(season) {
    if (season === "fall") return "FALL";
    if (season === "winter") return "WINTER";
    return "SPRING";
  }

  // ---- Layout --------------------------------------------------------------

  // The map is ALWAYS scaled to fit the canvas, aspect preserved, so the
  // board is never larger than the frame and no pan/zoom control is needed.
  // Below 640px the canvas draws an ACTION BOX instead: the bounding box of
  // every province named in the current phase, padded by one province and at
  // least 40% of the map, chosen deterministically from the state.
  function computeLayout(width, height, map, view) {
    var space = (map && map.space) || { width: 1000, height: 800 };
    var box = { x0: 0, y0: 0, x1: space.width, y1: space.height };
    if (width < 640 && map) {
      var hot = activeProvinces(view);
      var seen = 0;
      var bx0 = space.width, by0 = space.height, bx1 = 0, by1 = 0;
      hot.forEach(function (code) {
        var province = map.provinces[code];
        if (!province) return;
        seen += 1;
        bx0 = Math.min(bx0, province.label[0]);
        by0 = Math.min(by0, province.label[1]);
        bx1 = Math.max(bx1, province.label[0]);
        by1 = Math.max(by1, province.label[1]);
      });
      if (seen > 0) {
        var padX = Math.max(space.width * 0.2, 90);
        var padY = Math.max(space.height * 0.2, 90);
        box = { x0: bx0 - padX, y0: by0 - padY, x1: bx1 + padX,
          y1: by1 + padY };
        box.x0 = Math.max(0, box.x0);
        box.y0 = Math.max(0, box.y0);
        box.x1 = Math.min(space.width, box.x1);
        box.y1 = Math.min(space.height, box.y1);
      }
    }
    var boxW = Math.max(1, box.x1 - box.x0);
    var boxH = Math.max(1, box.y1 - box.y0);
    var scale = Math.min(width / boxW, height / boxH);
    return {
      width: width, height: height, scale: scale, box: box,
      offsetX: (width - boxW * scale) / 2 - box.x0 * scale,
      offsetY: (height - boxH * scale) / 2 - box.y0 * scale,
      small: width < 640
    };
  }

  function activeProvinces(view) {
    var out = [];
    function add(code) {
      if (code && out.indexOf(code) < 0) out.push(code);
    }
    (view.arrows || []).forEach(function (arrow) {
      add(arrow.from); add(arrow.to); add(arrow.aux);
    });
    (view.standoffs || []).forEach(add);
    if (out.length === 0) {
      (view.units || []).forEach(function (unit) { add(unit.province); });
    }
    return out;
  }

  function project(L, point) {
    return [point[0] * L.scale + L.offsetX, point[1] * L.scale + L.offsetY];
  }

  function anchorOf(map, L, code) {
    var province = map && map.provinces[code];
    if (!province) return null;
    return project(L, province.label);
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, map, view) {
    var w = canvas.width;
    var h = canvas.height;
    var now = view.now || Date.now();
    var L = computeLayout(w, h, map, view);
    var fx = view.effects || {};

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.28)";
    ctx.fillRect(0, 0, w, h);

    if (!map) {
      drawSchematic(ctx, w, h, view);
      return;
    }

    var ownerOf = {};
    (view.owners || []).forEach(function (entry) {
      ownerOf[entry.centre] = entry.power;
    });
    var seatOfPower = view.seatOfPower || [0, 1, 2, 3, 4, 5, 6];

    drawProvinces(ctx, L, map, view, ownerOf, seatOfPower);
    drawCentres(ctx, L, map, view, ownerOf, seatOfPower);
    drawNames(ctx, L, map, view);
    drawUnits(ctx, L, map, view, seatOfPower, now, fx);
    drawArrows(ctx, L, map, view, seatOfPower, now, fx);
    drawStandoffs(ctx, L, map, view);
    drawStabs(ctx, L, map, view, seatOfPower, now, fx);
    drawPress(ctx, L, map, view, seatOfPower, now, fx);
  }

  function drawSchematic(ctx, w, h, view) {
    // The map file could not be fetched. Still draw something honest: the
    // powers and their centre counts, so the frame is never blank.
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 16px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("MAP UNAVAILABLE — " + seasonLabel(view.season) + " " +
      (view.year || ""), w / 2, h * 0.3);
    (view.seats || []).forEach(function (seat, index) {
      ctx.fillStyle = COLOR_HEX[seatColor(index)];
      ctx.fillText(seat.power + "  " + seat.centres,
        w / 2, h * 0.42 + index * 22);
    });
    ctx.restore();
  }

  function drawProvinces(ctx, L, map, view, ownerOf, seatOfPower) {
    Object.keys(map.provinces).forEach(function (code) {
      var province = map.provinces[code];
      ctx.beginPath();
      province.poly.forEach(function (point, index) {
        var p = project(L, point);
        if (index === 0) ctx.moveTo(p[0], p[1]); else ctx.lineTo(p[0], p[1]);
      });
      ctx.closePath();
      var fill;
      if (province.kind === "sea") {
        fill = (code.charCodeAt(0) + code.charCodeAt(2)) % 2 ? SEA : SEA_DEEP;
      } else {
        fill = province.kind === "land" ? LAND_DIM : LAND;
        var owner = ownerOf[code];
        if (typeof owner === "number" && owner >= 0) {
          fill = mix(fill, COLOR_HEX[seatColor(seatOfPower[owner])], 0.42);
        }
      }
      ctx.fillStyle = fill;
      ctx.fill();
      ctx.strokeStyle = province.kind === "sea" ?
        "rgba(242, 232, 216, 0.10)" : "rgba(42, 31, 22, 0.55)";
      ctx.lineWidth = 1;
      ctx.stroke();
    });
  }

  function drawStar(ctx, x, y, radius, filled, color) {
    ctx.beginPath();
    for (var i = 0; i < 10; i++) {
      var angle = -Math.PI / 2 + i * Math.PI / 5;
      var r = i % 2 ? radius * 0.45 : radius;
      var px = x + Math.cos(angle) * r;
      var py = y + Math.sin(angle) * r;
      if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.closePath();
    if (filled) {
      ctx.fillStyle = color;
      ctx.fill();
    }
    ctx.strokeStyle = filled ? INK : color;
    ctx.lineWidth = 1.2;
    ctx.stroke();
  }

  function drawCentres(ctx, L, map, view, ownerOf, seatOfPower) {
    var radius = Math.max(4, 7 * L.scale);
    Object.keys(map.provinces).forEach(function (code) {
      var province = map.provinces[code];
      if (!province.centre) return;
      var p = project(L, province.dot);
      var owner = ownerOf[code];
      var owned = typeof owner === "number" && owner >= 0;
      var color = owned ?
        COLOR_HEX[seatColor(seatOfPower[owner])] : AMBER;
      drawStar(ctx, p[0], p[1], radius, owned, color);
    });
  }

  function drawNames(ctx, L, map, view) {
    // Below 640px only the provinces the current phase names are labelled,
    // and never below 9px: a label a spectator cannot read is noise.
    var size = Math.max(9, Math.round(11 * L.scale));
    var only = L.small ? activeProvinces(view) : null;
    ctx.save();
    ctx.font = "600 " + size + "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    Object.keys(map.provinces).forEach(function (code) {
      if (only && only.indexOf(code) < 0) return;
      var province = map.provinces[code];
      var p = project(L, province.label);
      if (p[0] < -40 || p[0] > L.width + 40) return;
      // Full names, never internal codes — a spectator reads "Burgundy".
      ctx.fillStyle = province.kind === "sea" ? "rgba(242,232,216,0.55)" :
        "rgba(42,31,22,0.75)";
      ctx.fillText(ellipsize(ctx, province.name, 120 * L.scale),
        p[0], p[1] + 15 * L.scale);
    });
    ctx.restore();
  }

  function unitAnchor(map, L, unit) {
    var province = map.provinces[unit.province];
    if (!province) return null;
    var point = province.label;
    if (unit.coast && province.coasts && province.coasts[unit.coast]) {
      point = province.coasts[unit.coast];
    }
    return project(L, point);
  }

  function drawUnits(ctx, L, map, view, seatOfPower, now, fx) {
    var size = Math.max(9, 17 * L.scale);
    (view.units || []).forEach(function (unit) {
      var p = unitAnchor(map, L, unit);
      if (!p) return;
      var seat = seatOfPower[unit.power];
      var color = unit.dislodged ? GHOST : COLOR_HEX[seatColor(seat)];
      var shake = 0;
      if (unit.dislodged && typeof fx.adjudicateAt === "number") {
        var age = now - fx.adjudicateAt;
        if (age < STAMP_MS) shake = Math.sin(age / 40) * 2;
      }
      ctx.save();
      ctx.translate(p[0] + shake, p[1]);
      ctx.shadowColor = "rgba(0,0,0,0.55)";
      ctx.shadowBlur = 4;
      if (unit.kind === "F") {
        // Fleet: a pennant on a short staff.
        ctx.fillStyle = color;
        ctx.beginPath();
        ctx.moveTo(-size * 0.42, -size * 0.55);
        ctx.lineTo(size * 0.55, -size * 0.2);
        ctx.lineTo(-size * 0.42, size * 0.15);
        ctx.closePath();
        ctx.fill();
        ctx.shadowColor = "transparent";
        ctx.strokeStyle = INK;
        ctx.lineWidth = 1.2;
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(-size * 0.42, -size * 0.6);
        ctx.lineTo(-size * 0.42, size * 0.6);
        ctx.stroke();
      } else {
        // Army: a solid block carrying the power's initial.
        ctx.fillStyle = color;
        roundRect(ctx, -size * 0.5, -size * 0.5, size, size, 2);
        ctx.fill();
        ctx.shadowColor = "transparent";
        ctx.strokeStyle = INK;
        ctx.lineWidth = 1.2;
        ctx.stroke();
        ctx.fillStyle = INK;
        ctx.font = "700 " + Math.round(size * 0.7) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(POWERS[unit.power].charAt(0), 0, 1);
      }
      ctx.restore();
      // Amber dashed halo while the table is waiting on this power.
      var seatState = (view.seats || [])[seat];
      if (seatState && seatState.pending && !view.done &&
          view.phase === "orders") {
        ctx.save();
        ctx.strokeStyle = AMBER;
        ctx.lineWidth = 2;
        ctx.setLineDash([4, 4]);
        ctx.beginPath();
        ctx.arc(p[0], p[1], size * 0.95, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }
    });
  }

  function arrowHead(ctx, x0, y0, x1, y1, size) {
    var angle = Math.atan2(y1 - y0, x1 - x0);
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x1 - Math.cos(angle - 0.45) * size,
      y1 - Math.sin(angle - 0.45) * size);
    ctx.lineTo(x1 - Math.cos(angle + 0.45) * size,
      y1 - Math.sin(angle + 0.45) * size);
    ctx.closePath();
    ctx.fill();
  }

  function drawArrows(ctx, L, map, view, seatOfPower, now, fx) {
    var arrows = view.arrows || [];
    if (!arrows.length) return;
    var travel = typeof fx.adjudicateAt === "number" ?
      Math.min(1, (now - fx.adjudicateAt) / ARROW_MS) : 1;
    var eased = 1 - Math.pow(1 - travel, 3);
    arrows.forEach(function (arrow) {
      var from = anchorOf(map, L, arrow.from);
      var to = anchorOf(map, L, arrow.to);
      if (!from || !to) return;
      var color = COLOR_HEX[seatColor(seatOfPower[arrow.power])];
      var failed = arrow.outcome !== "success";
      ctx.save();
      ctx.lineWidth = Math.max(2, 3 * L.scale);
      if (arrow.kind === "move") {
        var tipX = from[0] + (to[0] - from[0]) * (failed ? eased * 0.72 :
          eased);
        var tipY = from[1] + (to[1] - from[1]) * (failed ? eased * 0.72 :
          eased);
        ctx.strokeStyle = failed ? rgba("#e0523a", 0.9) : color;
        ctx.fillStyle = ctx.strokeStyle;
        ctx.beginPath();
        ctx.moveTo(from[0], from[1]);
        ctx.lineTo(tipX, tipY);
        ctx.stroke();
        arrowHead(ctx, from[0], from[1], tipX, tipY,
          Math.max(6, 10 * L.scale));
      } else if (arrow.kind === "support") {
        ctx.strokeStyle = arrow.outcome === "success" ?
          rgba(AMBER, 0.85) : rgba(GHOST, 0.7);
        ctx.setLineDash([]);
        ctx.lineWidth = Math.max(1.5, 2.5 * L.scale);
        ctx.beginPath();
        var midX = (from[0] + to[0]) / 2;
        var midY = (from[1] + to[1]) / 2 - 14 * L.scale;
        ctx.moveTo(from[0], from[1]);
        ctx.quadraticCurveTo(midX, midY, to[0], to[1]);
        ctx.stroke();
        if (arrow.outcome === "success") {
          ctx.shadowColor = AMBER;
          ctx.shadowBlur = 8;
          ctx.stroke();
        }
      } else {
        ctx.strokeStyle = rgba(PAPER, 0.6);
        ctx.setLineDash([6, 5]);
        ctx.lineWidth = Math.max(1.5, 2 * L.scale);
        ctx.beginPath();
        ctx.moveTo(from[0], from[1]);
        ctx.lineTo(to[0], to[1]);
        ctx.stroke();
      }
      ctx.restore();
    });
  }

  function drawStandoffs(ctx, L, map, view) {
    (view.standoffs || []).forEach(function (code) {
      var p = anchorOf(map, L, code);
      if (!p) return;
      ctx.save();
      ctx.font = "700 " + Math.max(9, Math.round(11 * L.scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      var text = "STANDOFF";
      var pad = 5;
      var wide = ctx.measureText(text).width + pad * 2;
      ctx.fillStyle = "rgba(224, 82, 58, 0.92)";
      roundRect(ctx, p[0] - wide / 2, p[1] - 30 * L.scale - 9, wide, 18, 3);
      ctx.fill();
      ctx.fillStyle = PAPER;
      ctx.fillText(text, p[0], p[1] - 30 * L.scale);
      ctx.restore();
    });
  }

  function drawStabs(ctx, L, map, view, seatOfPower, now, fx) {
    var stabs = view.stabs || [];
    if (!stabs.length) return;
    stabs.forEach(function (stab) {
      var code = (stab.order || "").split(" ")[1];
      var p = anchorOf(map, L, code);
      if (!p) return;
      var age = typeof fx.adjudicateAt === "number" ?
        now - fx.adjudicateAt : STAMP_MS;
      var grow = Math.min(1, age / 260);
      ctx.save();
      ctx.translate(p[0], p[1]);
      ctx.rotate(-0.22);
      ctx.scale(1.6 - 0.6 * grow, 1.6 - 0.6 * grow);
      ctx.font = "700 " + Math.max(12, Math.round(16 * L.scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.strokeStyle = "#e0523a";
      ctx.lineWidth = 2;
      ctx.strokeText("STAB", 0, 0);
      ctx.fillStyle = "rgba(224, 82, 58, 0.85)";
      ctx.fillText("STAB", 0, 0);
      ctx.restore();
    });
  }

  function drawPress(ctx, L, map, view, seatOfPower, now, fx) {
    if (view.phase !== "press") return;
    var letters = view.press || [];
    if (!letters.length) return;
    var age = typeof fx.pressAt === "number" ? now - fx.pressAt : LETTER_MS;
    var t = Math.min(1, age / LETTER_MS);
    var capital = capitalAnchors(map, L, view, seatOfPower);
    letters.forEach(function (letter, index) {
      if (letter.public) return;
      var from = capital[letter.from];
      var to = capital[letter.to];
      if (!from || !to) return;
      var phase = Math.min(1, Math.max(0, t - index * 0.06) / 0.7);
      var eased = 1 - Math.pow(1 - phase, 2);
      var x = from[0] + (to[0] - from[0]) * eased;
      var y = from[1] + (to[1] - from[1]) * eased -
        Math.sin(eased * Math.PI) * 26 * L.scale;
      var power = POWERS.indexOf(letter.from);
      var color = power >= 0 ? COLOR_HEX[seatColor(seatOfPower[power])] :
        PAPER;
      var w = Math.max(10, 16 * L.scale);
      var h = w * 0.68;
      ctx.save();
      ctx.fillStyle = PAPER;
      ctx.strokeStyle = color;
      ctx.lineWidth = 1.6;
      ctx.fillRect(x - w / 2, y - h / 2, w, h);
      ctx.strokeRect(x - w / 2, y - h / 2, w, h);
      ctx.beginPath();
      ctx.moveTo(x - w / 2, y - h / 2);
      ctx.lineTo(x, y + h * 0.12);
      ctx.lineTo(x + w / 2, y - h / 2);
      ctx.stroke();
      ctx.restore();
    });
    // Broadcasts unfurl as a banner across the top of the map.
    var broadcast = null;
    letters.forEach(function (letter) {
      if (letter.public && !broadcast) broadcast = letter;
    });
    if (broadcast) {
      ctx.save();
      ctx.font = "600 " + Math.max(10, Math.round(13 * L.scale)) +
        "px -apple-system, system-ui, sans-serif";
      var text = broadcast.from + ": " + broadcast.text;
      var width = Math.min(L.width - 24, ctx.measureText(text).width + 20);
      ctx.fillStyle = "rgba(242, 232, 216, 0.92)";
      roundRect(ctx, (L.width - width) / 2, 8, width, 24, 4);
      ctx.fill();
      ctx.fillStyle = INK;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(ellipsize(ctx, text, width - 16), L.width / 2, 20);
      ctx.restore();
    }
  }

  var CAPITALS = {
    AUSTRIA: "VIE", ENGLAND: "LON", FRANCE: "PAR", GERMANY: "BER",
    ITALY: "ROM", RUSSIA: "MOS", TURKEY: "CON"
  };

  function capitalAnchors(map, L, view, seatOfPower) {
    var out = {};
    POWERS.forEach(function (power) {
      var anchor = anchorOf(map, L, CAPITALS[power]);
      if (anchor) out[power] = anchor;
    });
    return out;
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear power names and anonymous cog aliases; the
  // payload carries the policy names separately, spectator-side only. A name
  // map swaps them in wherever a name is RENDERED while the underlying
  // events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function powerWord(index) {
    return POWERS[index] ? titleCase(POWERS[index]) : "Someone";
  }

  function titleCase(text) {
    return text.charAt(0) + text.slice(1).toLowerCase();
  }

  function seatOfPowerIn(ctx, power) {
    return ctx.seatOfPower && typeof ctx.seatOfPower[power] === "number" ?
      ctx.seatOfPower[power] : power;
  }

  // `ctx` carries what a line needs from earlier events: the seat map and
  // the running centre counts.
  function describeEvent(event, nameMap, ctx) {
    switch (event.kind) {
      case "start":
        return "Spring 1901 — seven powers, 22 units, 34 supply centres.";
      case "phase":
        return null;
      case "press":
        return powerWord(event.power) +
          (event.broadcast ? " broadcasts: “" + event.broadcast + "”" :
            " writes " + ((event.letters || []).length) + " letters.");
      case "orders":
        return powerWord(event.power) + " orders " +
          (event.orders || []).length + " units.";
      case "adjudicate":
        return "Orders resolve.";
      case "retreat":
        return powerWord(event.power) + " retreats.";
      case "build":
        return powerWord(event.power) + " adjusts.";
      case "centres":
        return "Supply centres change hands.";
      case "end":
        return "Final.";
      default:
        return JSON.stringify(event);
    }
  }

  function blockHead(event) {
    if (!event) return "SETUP";
    if (event.kind === "start") return "SETUP";
    var season = seasonLabel(event.season);
    var phase = event.kind === "adjudicate" ? "ADJUDICATION" :
      event.kind === "centres" ? "CENTRES" :
      event.kind === "end" ? "FINAL" :
      (event.phaseKind || event.kind).toUpperCase();
    return season + " " + event.year + " · " + phase;
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // Renders the full transcript grouped into one section per phase.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = { seatOfPower: null };
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      if (event.kind === "start" && event.powers) {
        ctx.seatOfPower = [];
        event.powers.forEach(function (power, seat) {
          ctx.seatOfPower[power] = seat;
        });
      }
      var block = blockHead(event);
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + escapeHtml(block) + "</div>";
        lastBlock = block;
      }
      var future = i >= limit ? " feed-future" : "";
      var lines = diploFeedLines(event, nameMap, ctx);
      lines.forEach(function (line) {
        var seat = typeof line.seat === "number" ? " seat" +
          (line.seat % COLORS.length) : "";
        html += '<div class="feed-line ' + line.cls + seat + future + '">' +
          escapeHtml(line.text) + "</div>";
      });
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lineNodes = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lineNodes.length; l++) {
      if (!lineNodes[l].classList.contains("feed-future")) {
        target = lineNodes[l];
      }
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects.
  function makeEffects() {
    var seen = 0;
    var pressAt = null;
    var adjudicateAt = null;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "press") {
            pressAt = animate ? now : null;
          } else if (event.kind === "adjudicate") {
            adjudicateAt = animate ? now : null;
          }
        }
      },
      reset: function () {
        seen = 0; pressAt = null; adjudicateAt = null;
      },
      view: function () {
        return { effects: { pressAt: pressAt, adjudicateAt: adjudicateAt } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      parts.push(seasonLabel(state.season) + " " + (state.year || 1901));
      if (state.gameDone || state.done) {
        var lead = leaderOf(state);
        parts.push("FINAL");
        if (lead) parts.push(lead.power + " " + lead.centres + " CENTRES");
      } else {
        var phase = (state.phase || "").toUpperCase();
        if (phase === "ORDERS") phase = "ORDERS";
        if (phase === "BUILDS") phase = "BUILDS";
        parts.push(phase);
        var waiting = (state.seats || []).filter(function (s) {
          return s.pending;
        });
        parts.push(waiting.length ? "WAITING ON " + waiting.length :
          "ORDERS IN");
      }
    }
    return parts.join(" · ");
  }

  function leaderOf(state) {
    var best = null;
    (state.seats || []).forEach(function (seat) {
      if (!best || seat.centres > best.centres) best = seat;
    });
    return best;
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) +
        (seat.eliminated ? " dead" : "") + '">' +
        '<span class="plate-power">' + escapeHtml(seat.power || "") +
        "</span>" +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-centres">' + (seat.centres || 0) + "</span>" +
        '<span class="plate-units">' + (seat.units || 0) + " units</span>" +
        (seat.stabbedThisTurn ? '<span class="plate-stab">STAB</span>' : "") +
        (seat.eliminated ? '<span class="plate-out">OUT</span>' : "") +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline — scored on the centres held after " +
          (results.years || 0) + " year" +
          ((results.years || 0) === 1 ? "" : "s");
      case "solo":
        return "solo victory at " + SOLO_CENTRES + " centres";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below, and the
  // alliance graph replaying underneath. It lives inside #endscreen, so it
  // stops at var(--band) and every seek dismisses it.
  function updateEndscreen(container, results, show, nameMap, extras) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var centres = results.centres || [];
    var units = results.units || [];
    var powers = results.powers || [];
    var stabs = (extras && extras.stabs) || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = "ALL LEVEL";
    if (!level && topIndex >= 0) {
      verdict = escapeHtml(names[topIndex]) + " (" +
        escapeHtml(powers[topIndex] || "") + ")" +
        (results.reason === "solo" ? " SOLOED ON " + SOLO_CENTRES :
          " LED EUROPE");
    }
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.years || 0) + " YEAR" +
      ((results.years || 0) === 1 ? "" : "S") + " · " + TOTAL_CENTRES +
      " CENTRES</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">power</span>' +
      '<span class="end-head">centres</span>' +
      '<span class="end-head">units</span>' +
      '<span class="end-head">stabs</span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(powers[i] || "")) +
        cell(centres[i] || 0) +
        cell(units[i] || 0) +
        cell(stabs[i] || 0) +
        cell(((scores[i] || 0)).toFixed(3));
    });
    html += "</div>" + allianceGraphHtml() + "</div>";
    container.innerHTML = html;
    startAllianceGraph(container, extras && extras.pledgeYears,
      extras && extras.seatOfPower);
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.seatOfPower = state.seatOfPower || [0, 1, 2, 3, 4, 5, 6];
    view.units = state.units || [];
    view.owners = state.owners || [];
    view.arrows = state.arrows || [];
    view.stabs = state.stabs || [];
    view.standoffs = state.standoffs || [];
    view.press = state.press || [];
    view.year = state.year || 1901;
    view.season = state.season || "spring";
    view.phase = state.phase || "";
    view.years = state.years || 0;
    view.yearsPlayed = state.yearsPlayed || 0;
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame becomes a seven-seat state so the same scene
  // draws for a player-view page.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var seats = [];
    for (var i = 0; i < 7; i++) {
      seats.push({ power: POWERS[i], name: "Seat " + i, centres: 0, units: 0 });
    }
    var units = (data.board || []).map(function (unit) {
      return {
        power: Math.max(0, POWERS.indexOf(unit.power)),
        kind: unit.kind, province: unit.province, coast: unit.coast,
        dislodged: false
      };
    });
    var owners = (data.owners || []).map(function (entry) {
      return { centre: entry.centre, power: POWERS.indexOf(entry.power) };
    });
    owners.forEach(function (entry) {
      if (entry.power >= 0) seats[entry.power].centres += 1;
    });
    units.forEach(function (unit) { seats[unit.power].units += 1; });
    return {
      seats: seats, seatOfPower: [0, 1, 2, 3, 4, 5, 6], units: units,
      owners: owners, arrows: [], stabs: [], standoffs: [], press: [],
      year: data.year, season: data.season, phase: data.phase,
      years: data.years, yearsPlayed: data.yearsPlayed,
      gameDone: data.done, reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, centrebar, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
              buildCentreBar(options.centrebar, latest);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap,
                collectExtras(latest && latest.events || [], latest));
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per phase, a
  // separator each game-year, and one labelled, clickable beat button per
  // event (plus an extra beat for every stab inside an adjudication).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    var lastYear = null;
    var yearBreaks = [];
    events.forEach(function (event, i) {
      var block = blockHead(event);
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
      if (event.year && event.year !== lastYear) {
        if (lastYear !== null) yearBreaks.push(i);
        lastYear = event.year;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
    });
    yearBreaks.forEach(function (startIdx) {
      var sep = document.createElement("div");
      sep.className = "round-sep";
      sep.style.left = (startIdx / events.length * 100) + "%";
      container.appendChild(sep);
    });
    events.forEach(function (event, i) {
      markDiploBeat(container, event, i, events.length, onSeek);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      if (evt.target && evt.target.classList &&
          evt.target.classList.contains("beat-marker")) {
        return;    // the beat's own click handler seeks
      }
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           centrebar, endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", year: 1901 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        buildCentreBar(options.centrebar, currentState());
        // Called on EVERY index change, so every seek dismisses the endcard.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap,
          collectExtras(events, currentState()));
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: press and
        // adjudication get read, an order set less so.
        var shown = index > 0 ? events[index - 1] : null;
        var kind = shown && shown.kind;
        var stepMs = kind === "adjudicate" ? 2200 :
          kind === "press" ? 1200 :
          kind === "centres" ? 1600 :
          kind === "end" ? 2000 :
          kind === "orders" ? 700 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  // =========================================================================
  // cogplomacy additions to the inherited cogame-bullwhip chrome
  // =========================================================================
  // Everything below is this game's own; nothing above is rewritten. The
  // builders here are deliberately named markDiploBeat / buildCentreBar and
  // friends so that no name in this block can ever shadow one the chrome
  // above defines (cogame-tandem, 2026-08-23); tests/test_viewer.nim asserts
  // the two name sets are disjoint.

  function diploBeatKinds(event) {
    // One beat per event, plus an extra STAB beat for every stab inside an
    // adjudication. The appended CSS defines a rule for each kind returned.
    var kinds = [];
    switch (event.kind) {
      case "press": kinds.push("press"); break;
      case "orders": kinds.push("orders"); break;
      case "adjudicate":
        kinds.push("adjudicate");
        (event.stabs || []).forEach(function () { kinds.push("stab"); });
        break;
      case "retreat": kinds.push("retreat"); break;
      case "build": kinds.push("build"); break;
      case "centres": kinds.push("centres"); break;
      case "end": kinds.push("end"); break;
      default: break;
    }
    return kinds;
  }

  function diploSeasonTag(event) {
    var letter = event.season === "fall" ? "F" :
      event.season === "winter" ? "W" : "S";
    return letter + (event.year || 1901);
  }

  function diploBeatLabel(event, kind, stabIndex) {
    var tag = diploSeasonTag(event);
    switch (kind) {
      case "press": {
        var letters = event.letters || [];
        var to = null;
        letters.forEach(function (letter) {
          if (to === null && letter.to >= 0) to = letter.to;
        });
        return tag + " · PRESS · " + powerWord(event.power) +
          (to !== null ? " writes to " + powerWord(to) : " broadcasts");
      }
      case "orders":
        return tag + " · ORDERS · " + powerWord(event.power);
      case "adjudicate":
        return tag + " · ADJUDICATION";
      case "stab": {
        var stab = (event.stabs || [])[stabIndex] || {};
        return "STAB · " + powerWord(stab.power) + " breaks " +
          (stab.kind || "a pledge") +
          (stab.pledgeTo >= 0 ? " with " + powerWord(stab.pledgeTo) :
            " with everyone");
      }
      case "retreat":
        return tag + " · RETREAT · " + powerWord(event.power);
      case "build": {
        var adjustments = event.adjustments || [];
        var builds = adjustments.filter(function (a) {
          return a.action === "build";
        }).length;
        var sign = builds ? "+" + builds :
          "-" + (adjustments.length - builds);
        return tag + " · BUILD · " + powerWord(event.power) + " " + sign;
      }
      case "centres": {
        var counts = event.counts || [];
        var best = 0;
        var bestPower = 0;
        counts.forEach(function (value, power) {
          if (value > best) { best = value; bestPower = power; }
        });
        return tag + " · CENTRES · " + powerWord(bestPower) + " " + best;
      }
      case "end":
        return "FINAL";
      default:
        return tag;
    }
  }

  // A beat is a real, labelled <button>: keyboard reachable, screen-reader
  // readable, and it seeks on click.
  function markDiploBeat(container, event, index, total, onSeek) {
    var kinds = diploBeatKinds(event);
    var stabIndex = -1;
    kinds.forEach(function (kind) {
      if (kind === "stab") stabIndex += 1;
      var marker = document.createElement("button");
      marker.type = "button";
      marker.className = "beat-marker " + kind +
        (typeof event.seat === "number" && event.seat >= 0 ?
          " seat" + (event.seat % COLORS.length) : "");
      var label = diploBeatLabel(event, kind, stabIndex);
      marker.title = label;
      marker.setAttribute("aria-label", label);
      marker.style.left = ((index + 1) / Math.max(1, total) * 100) + "%";
      marker.onclick = function (evt) {
        evt.stopPropagation();
        onSeek(index + 1);
      };
      container.appendChild(marker);
    });
  }

  // #centrebar — the supply-centre bar race along the top: one seat-coloured
  // segment per power, width proportional to centres, a grey NEUTRAL tail
  // for unclaimed centres, and a thin line at the 18-centre solo threshold.
  function buildCentreBar(container, state) {
    if (!container || !state || !state.seats) return;
    var seats = state.seats;
    var claimed = 0;
    seats.forEach(function (seat) { claimed += seat.centres || 0; });
    var html = "";
    seats.forEach(function (seat, index) {
      var centres = seat.centres || 0;
      if (!centres) return;
      html += '<div class="cbseg ' + seatColor(index) + '" style="width:' +
        (centres / TOTAL_CENTRES * 100) + '%"><span class="cbname">' +
        escapeHtml(seat.power || "") + "</span>&nbsp;" + centres + "</div>";
    });
    var neutral = TOTAL_CENTRES - claimed;
    if (neutral > 0) {
      html += '<div class="cbseg neutral" style="width:' +
        (neutral / TOTAL_CENTRES * 100) + '%"><span class="cbname">' +
        "NEUTRAL</span>&nbsp;" + neutral + "</div>";
    }
    html += '<div class="cbsolo" style="left:' +
      (SOLO_CENTRES / TOTAL_CENTRES * 100) + '%"></div>';
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // The feed reads in words, so it needs the map's province names. The map
  // is data the renderer fetches; makeRenderer hands it here as soon as it
  // has it, and every lookup falls back to the code (or to a wording that
  // names no province at all) if the fetch failed.
  var DIPLO_PROVINCE_NAMES = {};
  var DIPLO_PROVINCE_CODES = [];

  function diploLearnProvinces(map) {
    if (!map || !map.provinces) return;
    Object.keys(map.provinces).forEach(function (code) {
      var province = map.provinces[code];
      DIPLO_PROVINCE_NAMES[code] = province.name || code;
      if (typeof province.id === "number") {
        DIPLO_PROVINCE_CODES[province.id] = code;
      }
    });
  }

  // "BUR" -> "Burgundy"; "STP/SC" -> "St Petersburg (SC)".
  function diploPlaceWords(code) {
    var text = String(code || "").trim().toUpperCase();
    if (!text) return "";
    var slash = text.indexOf("/");
    var base = slash < 0 ? text : text.slice(0, slash);
    var name = DIPLO_PROVINCE_NAMES[base] || base;
    return slash < 0 ? name : name + " (" + text.slice(slash + 1) + ")";
  }

  // Events name provinces by the sim's province id.
  function diploProvinceWords(id) {
    if (typeof id !== "number" || id < 0) return "";
    return diploPlaceWords(DIPLO_PROVINCE_CODES[id] || "");
  }

  // One order in canonical notation, spelled out: "A PAR - BUR" reads
  // "Paris → Burgundy", "F BRE S A PAR - BUR" reads "Brest supports
  // Paris → Burgundy". Anything that does not parse prints as it came.
  function diploOrderWords(text) {
    var parts = String(text || "").trim().toUpperCase().split(/\s+/);
    if (parts.length < 2) return text;
    if (DIPLO_PROVINCE_CODES.length > 0 &&
        !DIPLO_PROVINCE_NAMES[parts[1].split("/")[0]]) {
      return text;              // not an order this map can spell out
    }
    var origin = diploPlaceWords(parts[1]);
    if (!origin) return text;
    var verb = parts[2];
    if (!verb || verb === "H" || verb === "HOLD" || verb === "HOLDS") {
      return origin + " holds";
    }
    if (verb === "-" && parts.length > 3) {
      return origin + " → " + diploPlaceWords(parts[3]) +
        (parts.indexOf("VIA") > 2 ? " by convoy" : "");
    }
    if ((verb === "S" || verb === "SUPPORT") && parts.length > 4) {
      var aux = diploPlaceWords(parts[4]);
      if (parts[5] === "-" && parts.length > 6) {
        return origin + " supports " + aux + " → " + diploPlaceWords(parts[6]);
      }
      return origin + " supports " + aux;
    }
    if ((verb === "C" || verb === "CONVOY") && parts.length > 6) {
      return origin + " convoys " + diploPlaceWords(parts[4]) + " → " +
        diploPlaceWords(parts[6]);
    }
    return text;
  }

  // A move as its two places, for an adjudication line.
  function diploMoveWords(order) {
    var from = diploProvinceWords(order && order.unit && order.unit.province);
    var to = diploProvinceWords(order && order.target);
    if (!from) return "";
    return to ? from + " → " + to : from;
  }

  // Everything a feed line needs, in words a casual spectator can read —
  // "Burgundy", "STANDOFF", "6 centres", never "p42" or "okSupportMove".
  function diploFeedLines(event, nameMap, ctx) {
    var out = [];
    var seatOf = function (power) { return seatOfPowerIn(ctx, power); };
    function push(cls, text, power) {
      out.push({ cls: cls, text: text,
        seat: typeof power === "number" ? seatOf(power) : undefined });
    }
    switch (event.kind) {
      case "start":
        push("feed-press",
          "Seven powers open with 22 units and 34 supply centres.");
        break;
      case "phase":
        break;
      case "press": {
        if (event.broadcast) {
          push("feed-broadcast", powerWord(event.power) + " broadcasts: “" +
            nameMap.text(event.broadcast) + "”", event.power);
        }
        (event.letters || []).forEach(function (letter) {
          if (letter.to < 0) {
            // The broadcast rides in this list too, and is already shown.
            if (letter.text === event.broadcast) return;
            push("feed-broadcast", powerWord(letter.from) +
              " writes to everyone: “" + nameMap.text(letter.text) + "”",
            letter.from);
            return;
          }
          push("feed-letter", powerWord(letter.from) + " → " +
            powerWord(letter.to) + " (private): “" +
            nameMap.text(letter.text) + "”", letter.from);
        });
        (event.pledges || []).forEach(function (pledge) {
          push("feed-pledge", powerWord(pledge.from) + " pledges " +
            pledge.kind + " to " +
            (pledge.to < 0 ? "everyone" : powerWord(pledge.to)) + ".",
          pledge.from);
        });
        break;
      }
      case "orders": {
        var written = (event.orders || []).map(diploOrderWords).join("; ");
        push("feed-order", powerWord(event.power) + " orders " + written + ".",
          event.power);
        (event.illegal || []).forEach(function (bad) {
          push("feed-illegal", powerWord(event.power) + " ordered " +
            diploOrderWords(bad.raw) + " — " + diploWhyWords(bad.why) +
            "; it holds.",
          event.power);
        });
        break;
      }
      case "adjudicate": {
        (event.results || []).forEach(function (item) {
          if (item.outcome !== "bounce") return;
          var order = item.order || {};
          var move = diploMoveWords(order);
          push("feed-bounce", move ?
            powerWord(order.power) + "'s " + move + " bounces." :
            "A move bounces.", order.power);
        });
        (event.dislodged || []).forEach(function (item) {
          var unit = item.unit || {};
          var where = diploProvinceWords(unit.province);
          var from = diploProvinceWords(item.attackerFrom);
          push("feed-dislodge", where ?
            powerWord(unit.power) + "'s " + where +
              " is dislodged by an attack out of " + (from || "next door") +
              " and must retreat." :
            powerWord(unit.power) + " is dislodged and must retreat.",
          unit.power);
        });
        (event.standoffs || []).forEach(function (province) {
          var where = diploProvinceWords(province);
          push("feed-bounce", where ? "STANDOFF in " + where +
            " — nothing enters." : "STANDOFF — nothing enters.");
        });
        (event.stabs || []).forEach(function (stab) {
          push("feed-stab", "STAB — " + powerWord(stab.power) +
            " promised " +
            (stab.pledgeTo < 0 ? "everyone" : powerWord(stab.pledgeTo)) +
            " " + stab.kind + " and ordered " +
            diploOrderWords(stab.order) + ".", stab.power);
        });
        break;
      }
      case "retreat":
        (event.moves || []).forEach(function (move) {
          var unit = move.unit || {};
          var where = diploProvinceWords(unit.province);
          var to = diploProvinceWords(move.to);
          push("feed-dislodge", powerWord(event.power) + "'s " +
            (where || "dislodged unit") +
            (move.to >= 0 && to ? " retreats to " + to : " disbands") + ".",
          event.power);
        });
        break;
      case "build": {
        var acted = (event.adjustments || []).map(function (action) {
          var unit = action.unit || {};
          return (action.action === "build" ? "builds " : "disbands ") +
            (unit.kind === "F" ? "a fleet in " : "an army in ") +
            (diploProvinceWords(unit.province) || "the field");
        });
        push("feed-build", powerWord(event.power) + " " +
          (acted.length ? acted.join(" and ") : "makes no adjustment") + ".",
        event.power);
        break;
      }
      case "centres": {
        var parts = [];
        (event.counts || []).forEach(function (value, power) {
          var gained = (event.gained || [])[power] || 0;
          var lost = (event.lost || [])[power] || 0;
          parts.push(powerWord(power) + " " + value +
            (gained ? " (+" + gained + ")" : "") +
            (lost ? " (−" + lost + ")" : ""));
        });
        push("feed-centres", "Fall " + event.year + " centres: " +
          parts.join(", ") + ".");
        break;
      }
      case "end": {
        var counts = event.counts || [];
        var best = 0;
        var bestPower = 0;
        counts.forEach(function (value, power) {
          if (value > best) { best = value; bestPower = power; }
        });
        if (event.text === "solo") {
          push("feed-stab", powerWord(event.soloist >= 0 ? event.soloist :
            bestPower) + " holds " + best + " centres — SOLO VICTORY.");
        } else if (event.text === "deadline") {
          push("feed-centres", "Episode deadline — scored on the centres " +
            "held after " + event.year + ".");
        } else {
          push("feed-centres", "Final — " + powerWord(bestPower) + " " +
            best + " of " + TOTAL_CENTRES + " centres (" +
            (best / TOTAL_CENTRES).toFixed(3) + ").");
        }
        break;
      }
      default:
        break;
    }
    return out;
  }

  function diploWhyWords(why) {
    switch (why) {
      case "nonadjacent": return "not adjacent";
      case "wrongunit": return "not legal for that unit";
      case "notthere": return "no such unit";
      case "noconvoy": return "no convoy route";
      case "ambiguouscoast": return "the coast was not named";
      default: return "it could not be read";
    }
  }

  // Extras the endcard wants: how often each seat stabbed, and the pledge
  // graph year by year.
  function collectExtras(events, state) {
    var seatOfPower = (state && state.seatOfPower) || [0, 1, 2, 3, 4, 5, 6];
    var stabs = [0, 0, 0, 0, 0, 0, 0];
    var pledgeYears = [];
    var byYear = {};
    events.forEach(function (event) {
      if (event.kind === "press") {
        (event.pledges || []).forEach(function (pledge) {
          var year = event.year || 1901;
          byYear[year] = byYear[year] || [];
          byYear[year].push({ from: pledge.from, to: pledge.to,
            broken: false });
        });
      }
      if (event.kind === "adjudicate") {
        (event.stabs || []).forEach(function (stab) {
          var seat = seatOfPower[stab.power];
          if (typeof seat === "number") stabs[seat] += 1;
          var year = event.year || 1901;
          (byYear[year] || []).forEach(function (edge) {
            if (edge.from === stab.power && edge.to === stab.pledgeTo) {
              edge.broken = true;
            }
          });
        });
      }
    });
    Object.keys(byYear).sort().forEach(function (year) {
      pledgeYears.push({ year: Number(year), edges: byYear[year] });
    });
    return { stabs: stabs, pledgeYears: pledgeYears,
      seatOfPower: seatOfPower };
  }

  function allianceGraphHtml() {
    return '<div class="end-alliance">' +
      '<canvas class="end-alliance-canvas" width="260" height="180">' +
      "</canvas>" +
      '<div class="end-alliance-caption">alliance graph</div></div>';
  }

  // The endcard replays the alliance graph: seven nodes in a ring in seat
  // colours, an edge for every pledge made, green while kept and red on the
  // year it was broken, auto-advancing one game-year a second in a loop.
  function startAllianceGraph(container, pledgeYears, seatOfPower) {
    var canvas = container.querySelector(".end-alliance-canvas");
    if (!canvas) return;
    var caption = container.querySelector(".end-alliance-caption");
    var years = pledgeYears && pledgeYears.length ? pledgeYears : [];
    var ctx = canvas.getContext("2d");
    var frameIndex = 0;
    function drawRing() {
      var w = canvas.width;
      var h = canvas.height;
      ctx.clearRect(0, 0, w, h);
      var cx = w / 2;
      var cy = h / 2;
      var radius = Math.min(w, h) * 0.36;
      var nodes = [];
      for (var i = 0; i < 7; i++) {
        var angle = -Math.PI / 2 + i * Math.PI * 2 / 7;
        nodes.push([cx + Math.cos(angle) * radius,
          cy + Math.sin(angle) * radius]);
      }
      var frame = years.length ? years[frameIndex % years.length] : null;
      if (frame) {
        frame.edges.forEach(function (edge) {
          var a = nodes[edge.from];
          var targets = edge.to < 0 ? [0, 1, 2, 3, 4, 5, 6] : [edge.to];
          targets.forEach(function (to) {
            if (to === edge.from) return;
            var b = nodes[to];
            if (!a || !b) return;
            ctx.strokeStyle = edge.broken ? "#e0523a" : "#45a85e";
            ctx.lineWidth = edge.broken ? 2.5 : 1.5;
            ctx.beginPath();
            ctx.moveTo(a[0], a[1]);
            ctx.lineTo(b[0], b[1]);
            ctx.stroke();
          });
        });
      }
      nodes.forEach(function (node, power) {
        var seat = seatOfPower && typeof seatOfPower[power] === "number" ?
          seatOfPower[power] : power;
        ctx.fillStyle = COLOR_HEX[seatColor(seat)];
        ctx.beginPath();
        ctx.arc(node[0], node[1], 7, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = PAPER;
        ctx.font = "700 9px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(POWERS[power].slice(0, 3), node[0],
          node[1] - 14);
      });
      if (caption) {
        caption.textContent = frame ?
          "alliance graph · " + frame.year : "no pledges were made";
      }
    }
    drawRing();
    if (years.length > 1) {
      window.setInterval(function () {
        frameIndex += 1;
        drawRing();
      }, 1000);
    }
  }

  window.CogplomacyRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
