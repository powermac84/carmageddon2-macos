// carma2web: instantiate JIT-generated wasm modules and register them in the function table
mergeInto(LibraryManager.library, {
  $jitAddFn__deps: ['$wasmTable'],
  $jitAddFn: function (fn) {
    if (!Module.__jitNext || Module.__jitNext >= Module.__jitEnd) {
      var base = wasmTable.grow(1024);
      Module.__jitNext = base;
      Module.__jitEnd = base + 1024;
    }
    var idx = Module.__jitNext++;
    wasmTable.set(idx, fn);
    return idx;
  },
  $jitPump__deps: ['$jitAddFn', '$wasmTable'],
  $jitPump: function () {
    var J = Module.__jitJobs;
    if (!J) return;
    while (J.active < 4 && J.queue.length) {
      J.active++;
      (function (job) {
        WebAssembly.instantiate(job.bytes, Module.__jitImports).then(function (res) {
          wasmExports['jit_installed'](job.region, jitAddFn(res.instance.exports.f));
        }).catch(function (e) {
          err('jit compile failed for region ' + job.region + ': ' + e);
          if (!Module.__jitBad) Module.__jitBad = job.bytes;
          wasmExports['jit_installed'](job.region, 0);
        }).then(function () {
          J.active--; Module.__jitPending--;
          jitPump();
        });
      })(J.queue.shift());
    }
  },
  jit_js_compile__deps: ['$jitAddFn', '$jitPump', '$wasmTable'],
  jit_js_compile: function (ptr, len, region) {
    var bytes = HEAPU8.slice(ptr, ptr + len);
    if (!Module.__jitImports) {
      Module.__jitImports = { env: {
        memory: wasmMemory,
        table: wasmTable,
        interp: wasmExports['jit_h_interp'],
        mat: wasmExports['jit_h_mat'],
        fist: wasmExports['jit_h_fist'],
        fild64: wasmExports['jit_h_fild64'],
      } };
      Module.__jitPending = 0;
      Module.__jitJobs = {queue: [], active: 0};
    }
    /* Browser compilation stays off the frame's synchronous path. Limit the
     * number of in-flight modules instead of flooding the compiler at load. */
    if (ENVIRONMENT_IS_NODE || new URLSearchParams(location.search).has('jitsync')) {
      try {
        var inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), Module.__jitImports);
        wasmExports['jit_installed'](region, jitAddFn(inst.exports.f));
      } catch (e) {
        err('jit compile failed for region ' + region + ': ' + e);
        if (!Module.__jitBad) Module.__jitBad = bytes;
        wasmExports['jit_installed'](region, 0);
      }
      return;
    }
    Module.__jitPending++;
    Module.__jitJobs.queue.push({bytes: bytes, region: region});
    jitPump();
  },
});
