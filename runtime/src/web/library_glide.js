// carma2web: WebGL2 backend for the Glide emulation in glide.c
// State block layout (int32 unless noted) must match glide.c (GlState).
mergeInto(LibraryManager.library, {
  glide_gl_init: function (w, h) {
    var canvas = Module['canvas'];
    // render scale / MSAA ("3dfx-like" smooth output): Module.glideScale, Module.glideMsaa
    var scale = Math.max(1, Math.min(4, (Module.glideScale | 0) || 2));
    var gl = canvas.getContext('webgl2', { antialias: false, depth: false, alpha: false, preserveDrawingBuffer: false });
    if (!gl) { err('WebGL2 not available'); return 0; }
    var maxS = gl.getParameter(gl.MAX_SAMPLES) || 0;
    var colorSamples = Array.from(gl.getInternalformatParameter(gl.RENDERBUFFER, gl.RGBA8, gl.SAMPLES) || []);
    var depthSamples = Array.from(gl.getInternalformatParameter(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, gl.SAMPLES) || []);
    var supportedMsaa = [0].concat([2, 4, 8].filter(function (n) { return n <= maxS && colorSamples.indexOf(n) >= 0 && depthSamples.indexOf(n) >= 0; }));
    function chooseMsaa(n) { return supportedMsaa.filter(function (v) { return v <= n; }).pop() || 0; }
    var msaa = Module.glideMsaa === undefined ? 4 : (Module.glideMsaa | 0);
    msaa = chooseMsaa(msaa);
    var G = Module.__glide = { gl: gl, w: w, h: h, scale: scale, msaa: msaa, tex: [null], freeIds: [], cur: {},
      forceFilter: Module.glideFilter === undefined ? 1 : (Module.glideFilter | 0) };
    G.aniso = gl.getExtension('EXT_texture_filter_anisotropic');
    G.maxAnisotropy = G.aniso ? gl.getParameter(G.aniso.MAX_TEXTURE_MAX_ANISOTROPY_EXT) : 1;
    G.anisotropy = Math.max(1, Math.min(G.maxAnisotropy, Module.glideAnisotropy || 4));
    G.supportedMsaa = supportedMsaa;
    // Retail GOG 2.1.0.28: derive foliage identity from the game's own tree
    // models and two-sided leaf materials. Texture IDs are recycled, so match
    // decoded image content and dimensions instead of a transient GL handle.
    G.foliageEnabled = Module.glideFoliageDepth !== false;
    G.foliageHashes = new Set(); G.foliageMaterials = []; G.foliageDraws = 0;
    G.foliageSignature = function (bytes, fw, fh) {
      var hash = 2166136261, sum = 0;
      for (var i = 0; i < bytes.length; i++) {
        hash = Math.imul(hash ^ bytes[i], 16777619) >>> 0;
        sum = (sum + Math.imul(bytes[i], i + 1)) >>> 0;
      }
      return fw + 'x' + fh + ':' + hash + ':' + sum;
    };
    G.updateFoliageMaterials = function () {
      if (G.foliageScanFrame === G.frames) return;
      G.foliageScanFrame = G.frames;
      function good(p, n) { return p >= 65536 && p + n >= p && p + n <= HEAPU8.length; }
      function u(p) { return good(p, 4) ? HEAPU32[p >>> 2] : 0; }
      function name(p) {
        if (!good(p, 1)) return '';
        var result = '';
        for (var i = 0; i < 64 && good(p + i, 1); i++) { var c = HEAPU8[p + i]; if (!c) return result; if (c < 32 || c > 126) return ''; result += String.fromCharCode(c); }
        return '';
      }
      var root = u(0x74d44c), track = u(0x75bb60), race = u(0x75bbf8);
      if (!good(root, 100) || !good(track, 100) || name(u(root + 20)) !== 'Root') return;
      var generation = root + '/' + track + '/' + race;
      var now = performance.now();
      if (G.foliageGeneration === generation) {
        if (G.foliageScans >= 3 || now > G.foliageRecheckUntil || now < G.foliageNextScan) return;
      } else { G.foliageScans = 0; G.foliageRecheckUntil = now + 3000; }
      G.foliageScans++; G.foliageNextScan = now + 1000;
      // Exact model names in the licensed game's DATA/TreeSurgery.TXT.
      var models = new Set(['&01citree1', '&25citree2.act', '&06palmtree.act', '&72shrub01.act', 'tree01', 'tree02', 'tree03', '&26tree08.act', '&24pine.act', '&33pine.act', '&04pine01.act', '&05pine02.act', '&06pine03.act', '&78palmtree.act', '&75plant01.act', '&06treepot.act', '&09oaktree01.act']);
      var seen = new Set(), seenModels = new Set(), seenMaterials = new Set(), stack = [[root, 0]], hashes = new Set(), materials = [];
      while (stack.length && seen.size < 30000) {
        var item = stack.pop(), actor = item[0], depth = item[1];
        if (!good(actor, 100) || seen.has(actor) || depth > 64) continue;
        seen.add(actor);
        var next = u(actor), child = u(actor + 8);
        if (next) stack.push([next, depth]); if (child) stack.push([child, depth + 1]);
        var model = u(actor + 24), modelName = name(u(model + 4)).toLowerCase();
        if (!models.has(modelName) || seenModels.has(model)) continue;
        seenModels.add(model);
        var prepared = u(model + 76), count = good(prepared, 28) ? HEAPU16[(prepared + 8) >>> 1] : 0, groups = u(prepared + 24);
        if (count > 128 || !good(groups, count * 36)) continue;
        for (var j = 0; j < count; j++) {
          var material = u(u(groups + j * 36 + 8));
          if (!good(material, 156) || seenMaterials.has(material) || !(u(material + 32) & 0x1000)) continue;
          seenMaterials.add(material);
          var pixelmap = u(material + 64);
          if (!good(pixelmap, 68) || HEAPU8[pixelmap + 44] !== 18) continue;
          var fw = HEAPU16[(pixelmap + 52) >>> 1], fh = HEAPU16[(pixelmap + 54) >>> 1], stride = HEAP16[(pixelmap + 40) >>> 1];
          var bx = HEAPU16[(pixelmap + 48) >>> 1], by = HEAPU16[(pixelmap + 50) >>> 1], pixels = u(pixelmap + 8);
          if (!fw || !fh || fw > 256 || fh > 256 || stride < (bx + fw) * 2 || !good(pixels, (by + fh - 1) * stride + (bx + fw) * 2)) continue;
          var rgba = new Uint8Array(fw * fh * 4), offset = 0, transparent = false, visible = false;
          for (var y = 0; y < fh; y++) for (var x = 0; x < fw; x++) {
            var value = HEAPU16[(pixels + (by + y) * stride + (bx + x) * 2) >>> 1];
            rgba[offset++] = ((value >>> 8) & 15) * 17; rgba[offset++] = ((value >>> 4) & 15) * 17;
            rgba[offset++] = (value & 15) * 17; var alpha = ((value >>> 12) & 15) * 17; rgba[offset++] = alpha;
            if (alpha === 0) transparent = true; if (alpha > 127) visible = true;
          }
          if (!transparent || !visible) continue;
          var signature = G.foliageSignature(rgba, fw, fh); hashes.add(signature);
          materials.push({model: modelName, material: name(u(material + 4)), texture: name(u(pixelmap + 4)), signature: signature});
        }
      }
      G.foliageHashes = hashes; G.foliageMaterials = materials; G.foliageGeneration = generation;
      G.cur = {};
      var registryKey = materials.map(function (m) { return m.signature; }).sort().join('|');
      if (materials.length && registryKey !== G.foliageRegistryLog) out('Foliage depth: ' + materials.length + ' original leaf materials identified');
      G.foliageRegistryLog = registryKey;
    };
    Module.getFoliageRendering = function () {
      return {enabled: G.foliageEnabled, mode: G.msaa > 0 ? 'alpha-to-coverage' : 'alpha-cutout', materials: G.foliageMaterials.slice(), draws: G.foliageDraws, registryScans: G.foliageScans || 0};
    };
    Module.setFoliageRendering = function (enabled) {
      G.foliageEnabled = !!enabled; G.cur = {}; return Module.getFoliageRendering();
    };

    // widescreen: the GL target is vw x h "Glide pixels", vw following the window shape (>= 4:3)
    G.calcVw = function () {
      if (Module.glideWide === 0) return w;
      var cw = window.innerWidth || w, ch = window.innerHeight || h;
      var vw = Math.round(h * cw / ch / 2) * 2;
      return Math.max(w, Math.min(w * 2, vw));
    };
    G.fit = function () {
      var cw = window.innerWidth, ch = window.innerHeight, a = G.vw / h;
      var dw = Math.min(cw, ch * a), dh = dw / a;
      canvas.style.width = dw + 'px'; canvas.style.height = dh + 'px';
    };
    function mkfbo(fw, fh) {
      var f = gl.createFramebuffer(), t = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, fw, fh, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.bindFramebuffer(gl.FRAMEBUFFER, f);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
      f.tex = t;
      return f;
    }
    G.alloc = function (vw, quality) {
      quality = quality || G;
      var nextScale = quality.scale, nextMsaa = quality.msaa;
      var W = vw * nextScale, H = h * nextScale;
      var old = {fbo: G.fbo, color: G.color, depth: G.depth, rfbo: G.rfbo};
      var fbo = gl.createFramebuffer(), color = gl.createRenderbuffer(), depth = gl.createRenderbuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.bindRenderbuffer(gl.RENDERBUFFER, color);
      if (nextMsaa > 0) gl.renderbufferStorageMultisample(gl.RENDERBUFFER, nextMsaa, gl.RGBA8, W, H);
      else gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGBA8, W, H);
      gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, color);
      gl.bindRenderbuffer(gl.RENDERBUFFER, depth);
      if (nextMsaa > 0) gl.renderbufferStorageMultisample(gl.RENDERBUFFER, nextMsaa, gl.DEPTH_COMPONENT24, W, H);
      else gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, W, H);
      gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, depth);
      var complete = gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
      var rfbo = mkfbo(W, H);
      complete = complete && gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
      if (!complete || gl.getError() !== gl.NO_ERROR) {
        gl.deleteFramebuffer(fbo); gl.deleteRenderbuffer(color); gl.deleteRenderbuffer(depth);
        gl.deleteTexture(rfbo.tex); gl.deleteFramebuffer(rfbo);
        gl.bindFramebuffer(gl.FRAMEBUFFER, old.fbo || null);
        if (G.W) gl.viewport(0, 0, G.W, G.H);
        err('Glide: graphics setting could not allocate a complete framebuffer; keeping previous quality');
        return false;
      }
      G.fbo = fbo; G.color = color; G.depth = depth; G.rfbo = rfbo;
      G.vw = vw; G.W = W; G.H = H;
      scale = G.scale = nextScale; msaa = G.msaa = nextMsaa;
      if (!old.fbo) { canvas.width = W; canvas.height = H; }
      else G.resizeCanvas = true;
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.viewport(0, 0, W, H);
      gl.colorMask(true, true, true, true); gl.depthMask(true);
      gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      if (G.prog) { gl.useProgram(G.prog); gl.uniform2f(G.u.uScreen, vw, h); gl.uniform1f(G.u.uPointSize, scale); }
      if (G.qtex) {
        gl.bindTexture(gl.TEXTURE_2D, G.qtex);
        var qf = scale > 1 ? gl.LINEAR : gl.NEAREST;
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, qf); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, qf);
      }
      if (old.fbo) {
        gl.deleteFramebuffer(old.fbo); gl.deleteRenderbuffer(old.color); gl.deleteRenderbuffer(old.depth);
        gl.deleteTexture(old.rfbo.tex); gl.deleteFramebuffer(old.rfbo);
      }
      G.cur = {};
      G.fit();
      return true;
    };
    G.sfbo = mkfbo(w, h);
    if (!G.alloc(G.calcVw())) {
      G.scale = 1; G.msaa = 0;
      if (!G.alloc(G.calcVw())) return 0;
    }
    Module.getGraphicsQuality = function () {
      return {scale: G.scale, msaa: G.msaa, anisotropy: G.anisotropy, width: G.W, height: G.H,
        supportedMsaa: G.supportedMsaa.slice(), maxAnisotropy: G.maxAnisotropy, pending: G.pendingQuality || null};
    };
    Module.setGraphicsQuality = function (settings) {
      settings = settings || {};
      var requested = {scale: settings.scale === undefined ? G.scale : Math.max(1, Math.min(4, Math.round(+settings.scale) || 1)),
        msaa: settings.msaa === undefined ? G.msaa : chooseMsaa(Math.max(0, +settings.msaa || 0)),
        anisotropy: settings.anisotropy === undefined ? G.anisotropy : Math.max(1, Math.min(G.maxAnisotropy, +settings.anisotropy || 1))};
      G.pendingQuality = requested;
      return Module.getGraphicsQuality();
    };
    window.addEventListener('resize', function () { G.fit(); });
    out('Glide/WebGL: ' + G.W + 'x' + G.H + ' (x' + scale + '), MSAA ' + msaa + 'x, bilinear ' + (G.forceFilter ? 'forced' : 'as requested') + ', width ' + G.vw);
    var vs = '#version 300 es\n' +
      'in vec2 aPos; in float aDepth; in vec4 aColor; in vec3 aTex; in float aW;\n' +
      'uniform vec2 uScreen; uniform float uPointSize;\n' +
      'out vec4 vColor; out vec3 vTex; out float vW;\n' +
      'void main(){ gl_Position = vec4(aPos.x / uScreen.x * 2.0 - 1.0, 1.0 - aPos.y / uScreen.y * 2.0, aDepth * 2.0 - 1.0, 1.0);\n' +
      ' vColor = aColor / 255.0; vTex = aTex; vW = aW; gl_PointSize = uPointSize; }\n';
    var fs = '#version 300 es\nprecision highp float; precision highp int;\n' +
      'in vec4 vColor; in vec3 vTex; in float vW;\n' +
      'uniform sampler2D uTex; uniform int uTexOn;\n' +
      'uniform ivec4 uCC; uniform int uCCInv; uniform ivec4 uAC; uniform int uACInv;\n' +
      'uniform vec4 uConst; uniform int uFog; uniform vec3 uFogColor; uniform float uFogTable[64];\n' +
      'uniform int uChroma; uniform ivec3 uChromaKey; uniform int uFoliage;\n' +
      'out vec4 oColor;\n' +
      'float fogf(float w){ if (w < 1.0) return uFogTable[0]; float e = floor(log2(w)); float m = 8.0 - 8.0 / (w / exp2(e));\n' +
      ' float fi = clamp(4.0 * e + m, 0.0, 63.0); int i0 = int(floor(fi)); int i1 = min(i0 + 1, 63); return mix(uFogTable[i0], uFogTable[i1], fract(fi)); }\n' +
      'void main(){\n' +
      ' vec4 t = vec4(0.0, 0.0, 0.0, 1.0);\n' +
      ' if (uTexOn != 0) t = texture(uTex, vTex.xy / vTex.z);\n' +
      ' vec3 lc = uCC.z == 1 ? uConst.rgb : vColor.rgb;\n' +
      ' float la = uAC.z == 1 ? uConst.a : vColor.a;\n' +
      ' vec3 oc = uCC.w == 1 ? t.rgb : (uCC.w == 2 ? uConst.rgb : vColor.rgb);\n' +
      ' float oa = uAC.w == 1 ? t.a : (uAC.w == 2 ? uConst.a : vColor.a);\n' +
      ' vec3 f; int cf = uCC.y;\n' +
      ' if (cf == 0) f = vec3(0.0); else if (cf == 1) f = lc; else if (cf == 2) f = vec3(oa); else if (cf == 3) f = vec3(la);\n' +
      ' else if (cf == 4) f = vec3(t.a); else if (cf == 9) f = 1.0 - lc; else if (cf == 10) f = vec3(1.0 - oa);\n' +
      ' else if (cf == 11) f = vec3(1.0 - la); else if (cf == 12) f = vec3(1.0 - t.a); else f = vec3(1.0);\n' +
      ' vec3 c; int fn = uCC.x;\n' +
      ' if (fn == 0) c = vec3(0.0); else if (fn == 1) c = lc; else if (fn == 2) c = vec3(la); else if (fn == 3) c = f * oc;\n' +
      ' else if (fn == 4) c = f * oc + lc; else if (fn == 5) c = f * oc + la; else if (fn == 6) c = f * (oc - lc);\n' +
      ' else if (fn == 7) c = f * (oc - lc) + lc; else if (fn == 8) c = f * (oc - lc) + la; else if (fn == 9) c = lc - f * lc;\n' +
      ' else if (fn == 16) c = la - f * lc; else c = lc;\n' +
      ' c = clamp(c, 0.0, 1.0); if (uCCInv != 0) c = 1.0 - c;\n' +
      ' float fa; int af = uAC.y;\n' +
      ' if (af == 0) fa = 0.0; else if (af == 1 || af == 3) fa = la; else if (af == 2) fa = oa; else if (af == 4) fa = t.a;\n' +
      ' else if (af == 9 || af == 11) fa = 1.0 - la; else if (af == 10) fa = 1.0 - oa; else if (af == 12) fa = 1.0 - t.a; else fa = 1.0;\n' +
      ' float a; int afn = uAC.x;\n' +
      ' if (afn == 0) a = 0.0; else if (afn == 1 || afn == 2) a = la; else if (afn == 3) a = fa * oa; else if (afn == 4 || afn == 5) a = fa * oa + la;\n' +
      ' else if (afn == 6) a = fa * (oa - la); else if (afn == 7 || afn == 8) a = fa * (oa - la) + la; else if (afn == 9 || afn == 16) a = la - fa * la; else a = la;\n' +
      ' a = clamp(a, 0.0, 1.0); if (uACInv != 0) a = 1.0 - a;\n' +
      ' if (uChroma != 0) { ivec3 q = ivec3(floor(clamp(oc, 0.0, 1.0) * 255.0 + 0.5)); if (q == uChromaKey) discard; }\n' +
      ' if (uFog == 1) c = mix(c, uFogColor, vColor.a); else if (uFog == 2) c = mix(c, uFogColor, fogf(vW));\n' +
      ' if (uFoliage == 1) { if (a < 0.5) discard; a = 1.0; } else if (uFoliage == 2 && a <= 0.0) discard;\n' +
      ' oColor = vec4(c, a); }\n';
    function sh(type, src) { var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) err('glide shader: ' + gl.getShaderInfoLog(s)); return s; }
    var p = gl.createProgram();
    gl.attachShader(p, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs));
    gl.bindAttribLocation(p, 0, 'aPos'); gl.bindAttribLocation(p, 1, 'aDepth'); gl.bindAttribLocation(p, 2, 'aColor');
    gl.bindAttribLocation(p, 3, 'aTex'); gl.bindAttribLocation(p, 4, 'aW');
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) err('glide link: ' + gl.getProgramInfoLog(p));
    G.prog = p;
    gl.useProgram(p);
    var U = G.u = {};
    ['uScreen', 'uPointSize', 'uTex', 'uTexOn', 'uCC', 'uCCInv', 'uAC', 'uACInv', 'uConst', 'uFog', 'uFogColor', 'uFogTable', 'uChroma', 'uChromaKey', 'uFoliage'].forEach(function (n) { U[n] = gl.getUniformLocation(p, n); });
    gl.uniform2f(U.uScreen, G.vw, h);
    gl.uniform1f(U.uPointSize, scale);
    gl.uniform1i(U.uTex, 0);
    G.vao = gl.createVertexArray(); gl.bindVertexArray(G.vao);
    G.vbo = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, G.vbo);
    var S = 44;
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, S, 0);
    gl.enableVertexAttribArray(1); gl.vertexAttribPointer(1, 1, gl.FLOAT, false, S, 8);
    gl.enableVertexAttribArray(2); gl.vertexAttribPointer(2, 4, gl.FLOAT, false, S, 12);
    gl.enableVertexAttribArray(3); gl.vertexAttribPointer(3, 3, gl.FLOAT, false, S, 28);
    gl.enableVertexAttribArray(4); gl.vertexAttribPointer(4, 1, gl.FLOAT, false, S, 40);
    // quad program for LFB composites
    var qvs = '#version 300 es\nin vec2 aPos; out vec2 vUV; uniform vec4 uRect; uniform vec2 uScreen;\n' +
      'void main(){ vec2 px = uRect.xy + aPos * uRect.zw; vUV = aPos; gl_Position = vec4(px.x / uScreen.x * 2.0 - 1.0, 1.0 - px.y / uScreen.y * 2.0, 0.0, 1.0); }\n';
    var qfs = '#version 300 es\nprecision mediump float; in vec2 vUV; uniform sampler2D uTex; out vec4 o;\n' +
      'void main(){ vec4 c = texture(uTex, vUV); if (c.a < 0.5) discard; o = vec4(c.rgb, 1.0); }\n';
    var q = gl.createProgram();
    gl.attachShader(q, sh(gl.VERTEX_SHADER, qvs)); gl.attachShader(q, sh(gl.FRAGMENT_SHADER, qfs));
    gl.bindAttribLocation(q, 0, 'aPos'); gl.linkProgram(q);
    G.qprog = q; G.qRect = gl.getUniformLocation(q, 'uRect'); G.qScreen = gl.getUniformLocation(q, 'uScreen');
    G.qvao = gl.createVertexArray(); gl.bindVertexArray(G.qvao);
    G.qvbo = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, G.qvbo);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 8, 0);
    G.qtex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, G.qtex);
    var qf = scale > 1 ? gl.LINEAR : gl.NEAREST;
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, qf); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, qf);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.bindVertexArray(G.vao);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    return 1;
  },

  glide_gl_vw: function () { return Module.__glide ? Module.__glide.vw : 640; },

  glide_gl_tex_create: function (w, h, levels, ptrs, format) {
    var G = Module.__glide, gl = G.gl;
    var t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    var lw = w, lh = h;
    for (var l = 0; l < levels; l++) {
      var p = HEAP32[(ptrs >> 2) + l];
      gl.texImage2D(gl.TEXTURE_2D, l, gl.RGBA8, lw, lh, 0, gl.RGBA, gl.UNSIGNED_BYTE, HEAPU8.subarray(p, p + lw * lh * 4));
      lw = Math.max(1, lw >> 1); lh = Math.max(1, lh >> 1);
    }
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, levels - 1);
    var id = G.freeIds.length ? G.freeIds.pop() : G.tex.length;
    var first = HEAP32[ptrs >> 2];
    var foliageSignature = format === 12 ? G.foliageSignature(HEAPU8.subarray(first, first + w * h * 4), w, h) : null;
    G.tex[id] = { t: t, w: w, h: h, format: format, levels: levels, filt: -1, cs: -1, ct: -1, foliageSignature: foliageSignature };
    G.cur = {};
    return id;
  },

  glide_gl_tex_delete: function (id) {
    var G = Module.__glide;
    if (!G || !G.tex[id]) return;
    G.gl.deleteTexture(G.tex[id].t);
    G.tex[id] = null;
    G.freeIds.push(id);
    G.cur = {};
  },

  glide_gl_fog: function (colorPtr, tablePtr) {
    var G = Module.__glide, gl = G.gl;
    G.cur = {};
    gl.useProgram(G.prog);
    gl.uniform3f(G.u.uFogColor, HEAPF32[colorPtr >> 2], HEAPF32[(colorPtr >> 2) + 1], HEAPF32[(colorPtr >> 2) + 2]);
    gl.uniform1fv(G.u.uFogTable, HEAPF32.subarray(tablePtr >> 2, (tablePtr >> 2) + 64));
  },

  glide_gl_draw: function (prim, vptr, nverts, sptr) {
    if (Module.noRaster) return;
    var G = Module.__glide, gl = G.gl, s = sptr >> 2, U = G.u;
    if (!HEAP32[s + 25] && HEAP32[s + 15]) G.updateFoliageMaterials();
    var C = G.cur;
    G.draws = (G.draws || 0) + 1; G.verts = (G.verts || 0) + nverts;
    if (!C.bound) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, G.fbo);
      gl.useProgram(G.prog);
      gl.bindVertexArray(G.vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, G.vbo);
      C.bound = true;
    }
    var texId = HEAP32[s];
    var T = texId > 0 ? G.tex[texId] : null;
    // Only the game's identified two-sided cutout leaves use depth coverage.
    // Retain ordinary alpha blending for glass, HUD, particles, and tree bark.
    var foliage = !!(G.foliageEnabled && T && G.foliageHashes.has(T.foliageSignature) && !HEAP32[s + 25] &&
      HEAP32[s + 15] && HEAP32[s + 17] === 0 && HEAP32[s + 11] === 1 && HEAP32[s + 12] === 5 &&
      HEAP32[s + 6] === 3 && HEAP32[s + 7] === 4 && HEAPF32[s + 29] === 255);
    var foliageMode = foliage ? (G.msaa > 0 ? 2 : 1) : 0;
    if (C.foliage !== foliageMode) {
      gl.uniform1i(U.uFoliage, foliageMode);
      if (foliageMode === 2) gl.enable(gl.SAMPLE_ALPHA_TO_COVERAGE); else gl.disable(gl.SAMPLE_ALPHA_TO_COVERAGE);
      C.foliage = foliageMode;
    }
    if (foliage) G.foliageDraws++;
    if (T) {
      if (C.tex !== texId) { gl.bindTexture(gl.TEXTURE_2D, T.t); C.tex = texId; }
      var filt = HEAP32[s + 22] | (G.forceFilter && T.levels > 1 && !HEAP32[s + 25] ? 1 : 0), cs = HEAP32[s + 23], ct = HEAP32[s + 24];
      if (T.filt !== filt) {
        T.filt = filt;
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filt ? gl.LINEAR : gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, T.levels > 1 ? (filt ? gl.LINEAR_MIPMAP_LINEAR : gl.NEAREST_MIPMAP_NEAREST) : (filt ? gl.LINEAR : gl.NEAREST));
        if (G.aniso) gl.texParameterf(gl.TEXTURE_2D, G.aniso.TEXTURE_MAX_ANISOTROPY_EXT, filt && T.levels > 1 ? G.anisotropy : 1);
      }
      if (T.cs !== cs) { T.cs = cs; gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, cs ? gl.CLAMP_TO_EDGE : gl.REPEAT); }
      if (T.ct !== ct) { T.ct = ct; gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, ct ? gl.CLAMP_TO_EDGE : gl.REPEAT); }
    }
    var texOn = T ? 1 : 0;
    if (C.texOn !== texOn) { gl.uniform1i(U.uTexOn, texOn); C.texOn = texOn; }
    // combine state: compare the int block 1..10 and const floats as a key
    var key = HEAP32[s + 1] + ',' + HEAP32[s + 2] + ',' + HEAP32[s + 3] + ',' + HEAP32[s + 4] + ',' + HEAP32[s + 5] + ',' +
      HEAP32[s + 6] + ',' + HEAP32[s + 7] + ',' + HEAP32[s + 8] + ',' + HEAP32[s + 9] + ',' + HEAP32[s + 10];
    if (C.comb !== key) {
      gl.uniform4i(U.uCC, HEAP32[s + 1], HEAP32[s + 2], HEAP32[s + 3], HEAP32[s + 4]);
      gl.uniform1i(U.uCCInv, HEAP32[s + 5]);
      gl.uniform4i(U.uAC, HEAP32[s + 6], HEAP32[s + 7], HEAP32[s + 8], HEAP32[s + 9]);
      gl.uniform1i(U.uACInv, HEAP32[s + 10]);
      C.comb = key;
    }
    var c0 = HEAPF32[s + 26], c1 = HEAPF32[s + 27], c2 = HEAPF32[s + 28], c3 = HEAPF32[s + 29];
    if (C.c0 !== c0 || C.c1 !== c1 || C.c2 !== c2 || C.c3 !== c3) {
      gl.uniform4f(U.uConst, c0 / 255, c1 / 255, c2 / 255, c3 / 255);
      C.c0 = c0; C.c1 = c1; C.c2 = c2; C.c3 = c3;
    }
    var fog = HEAP32[s + 19] & 0xff;
    fog = fog === 1 ? 1 : (fog === 2 ? 2 : 0);
    if (C.fog !== fog) { gl.uniform1i(U.uFog, fog); C.fog = fog; }
    var chroma = HEAP32[s + 20], ck = HEAP32[s + 21];
    if (C.chroma !== chroma || C.ck !== ck) {
      gl.uniform1i(U.uChroma, chroma);
      gl.uniform3i(U.uChromaKey, (ck >> 16) & 255, (ck >> 8) & 255, ck & 255);
      C.chroma = chroma; C.ck = ck;
    }
    var bs = HEAP32[s + 11], bd = HEAP32[s + 12];
    var bkey = bs * 64 + bd + (foliage ? 10000 : 0);
    if (C.blend !== bkey) {
      if (foliage || (bs === 4 && bd === 0)) gl.disable(gl.BLEND);
      else {
        gl.enable(gl.BLEND);
        var src = [gl.ZERO, gl.SRC_ALPHA, gl.DST_COLOR, gl.ONE, gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE_MINUS_DST_COLOR, gl.ZERO];
        var dst = [gl.ZERO, gl.SRC_ALPHA, gl.SRC_COLOR, gl.ONE, gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE_MINUS_SRC_COLOR, gl.ZERO];
        var sf = bs === 15 ? gl.SRC_ALPHA_SATURATE : (src[bs] !== undefined ? src[bs] : gl.ONE);
        var df = bd === 15 ? gl.ONE : (dst[bd] !== undefined ? dst[bd] : gl.ZERO);
        gl.blendFunc(sf, df);
      }
      C.blend = bkey;
    }
    var dmode = HEAP32[s + 15], dfunc = HEAP32[s + 16], dmask = HEAP32[s + 17];
    if (foliage) dmask = 1;
    var dkey = (foliage ? 10000 : 0) + (dmode !== 0 ? 1 : 0) * 1000 + dfunc * 10 + (dmode !== 0 && dmask !== 0 ? 1 : 0);
    if (C.depth !== dkey) {
      if (dmode === 0) gl.disable(gl.DEPTH_TEST);
      else { gl.enable(gl.DEPTH_TEST); gl.depthFunc(gl.NEVER + dfunc); }
      gl.depthMask(dmode !== 0 && dmask !== 0);
      C.depth = dkey;
    }
    var cm = HEAP32[s + 18] !== 0;
    if (C.cm !== cm) { gl.colorMask(cm, cm, cm, cm); C.cm = cm; }
    gl.bufferData(gl.ARRAY_BUFFER, HEAPF32.subarray(vptr >> 2, (vptr >> 2) + nverts * 11), gl.STREAM_DRAW);
    gl.drawArrays(prim === 1 ? gl.LINES : (prim === 0 ? gl.POINTS : gl.TRIANGLES), 0, nverts);
  },

  glide_gl_clear: function (r, g, b, depth, colorMask, depthMask) {
    var G = Module.__glide, gl = G.gl;
    G.cur = {};
    gl.bindFramebuffer(gl.FRAMEBUFFER, G.fbo);
    var bits = 0;
    gl.colorMask(true, true, true, true);
    if (colorMask) { gl.clearColor(r / 255, g / 255, b / 255, 1); bits |= gl.COLOR_BUFFER_BIT; }
    if (depthMask) { gl.depthMask(true); gl.clearDepth(depth); bits |= gl.DEPTH_BUFFER_BIT; }
    if (bits) gl.clear(bits);
  },

  glide_gl_swap: function (pillarbox) {
    var G = Module.__glide, gl = G.gl;
    gl.disable(gl.SAMPLE_ALPHA_TO_COVERAGE);
    if (G.resizeCanvas) { Module.canvas.width = G.W; Module.canvas.height = G.H; G.resizeCanvas = false; }
    G.cur = {};
    G.frames = (G.frames || 0) + 1;
    if (pillarbox && G.vw > G.w) {
      /* menus are 4:3 in the centre: keep the side bars black */
      var side = ((G.vw - G.w) / 2) * G.scale;
      gl.bindFramebuffer(gl.FRAMEBUFFER, G.fbo);
      gl.enable(gl.SCISSOR_TEST);
      gl.colorMask(true, true, true, true);
      gl.clearColor(0, 0, 0, 1);
      gl.scissor(0, 0, Math.ceil(side), G.H); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.scissor(G.W - Math.ceil(side), 0, Math.ceil(side), G.H); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.disable(gl.SCISSOR_TEST);
    }
    /* resolve MSAA into an RGBA8 texture first: a multisampled blit cannot convert to the canvas format */
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, G.fbo);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, G.rfbo);
    gl.blitFramebuffer(0, 0, G.W, G.H, 0, 0, G.W, G.H, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, G.rfbo);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
    gl.blitFramebuffer(0, 0, G.W, G.H, 0, 0, G.W, G.H, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    gl.bindFramebuffer(gl.FRAMEBUFFER, G.fbo);
    var vw = G.calcVw();
    var next = G.pendingQuality;
    if (next) {
      G.pendingQuality = null;
      if (next.scale !== G.scale || next.msaa !== G.msaa || vw !== G.vw) G.alloc(vw, next);
      if (next.anisotropy !== G.anisotropy) {
        G.anisotropy = next.anisotropy;
        G.tex.forEach(function (t) { if (t) t.filt = -1; });
      }
      Module.glideScale = G.scale; Module.glideMsaa = G.msaa; Module.glideAnisotropy = G.anisotropy;
      try { localStorage.setItem('carma2.graphics.v1', JSON.stringify({scale:G.scale,msaa:G.msaa,anisotropy:G.anisotropy})); } catch (e) {}
      out('Glide quality: ' + G.W + 'x' + G.H + ', MSAA ' + G.msaa + ', anisotropy ' + G.anisotropy);
    } else if (vw !== G.vw) G.alloc(vw);
    return G.vw;
  },

  // draw an RGBA image (alpha 0 = keep) over the back buffer at x,y
  glide_gl_blit: function (x, y, dw, dh, w, h, ptr) {
    var G = Module.__glide, gl = G.gl;
    G.cur = {};
    gl.bindFramebuffer(gl.FRAMEBUFFER, G.fbo);
    gl.useProgram(G.qprog);
    gl.bindVertexArray(G.qvao);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, G.qtex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, HEAPU8.subarray(ptr, ptr + w * h * 4));
    gl.uniform4f(G.qRect, x, y, dw, dh);
    gl.uniform2f(G.qScreen, G.vw, G.h);
    gl.disable(gl.SAMPLE_ALPHA_TO_COVERAGE); gl.disable(gl.BLEND); gl.disable(gl.DEPTH_TEST); gl.depthMask(false); gl.colorMask(true, true, true, true);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    gl.bindVertexArray(G.vao);
    gl.useProgram(G.prog);
    G.cur.tex = -1;
  },

  // read back the back buffer as RGBA (top-down rows)
  glide_gl_read: function (x, y, w, h, ptr) {
    var G = Module.__glide, gl = G.gl;
    G.cur = {};
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, G.fbo);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, G.rfbo);
    gl.blitFramebuffer(0, 0, G.W, G.H, 0, 0, G.W, G.H, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, G.rfbo);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, G.sfbo);
    var ox = Math.round((G.vw - G.w) / 2 * G.scale);
    gl.blitFramebuffer(ox, 0, ox + G.w * G.scale, G.H, 0, 0, G.w, G.h, gl.COLOR_BUFFER_BIT, gl.LINEAR);
    gl.bindFramebuffer(gl.FRAMEBUFFER, G.sfbo);
    gl.readPixels(x, y, w, h, gl.RGBA, gl.UNSIGNED_BYTE, HEAPU8.subarray(ptr, ptr + w * h * 4));
    gl.bindFramebuffer(gl.FRAMEBUFFER, G.fbo);
  },
});
