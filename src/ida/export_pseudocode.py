import idaapi
import idc
import idautils
import ida_hexrays
import re
import os

if not ida_hexrays.init_hexrays_plugin():
   raise RuntimeError("Hex-Rays decompiler not available")

def log_print(*args: object,  sep: str | None =" ", end: str | None ="\n"):
    msg = sep.join(str(arg) for arg in args)
    print(f'[{__file__}] {msg}', sep=sep, end=end)

def export(name_pattern: str, out_filename: str):
    with open(out_filename, "w", encoding="utf-8") as f:

        name_pattern_regexpr = re.compile(name_pattern)

        for ea in idautils.Functions():
            func_name_dm = idaapi.get_ea_name(ea, idaapi.GN_SHORT | idaapi.GN_DEMANGLED)

            if name_pattern_regexpr.match(func_name_dm) is not None:
                try:
                    cfunc = ida_hexrays.decompile(ea, None, ida_hexrays.DECOMP_NO_FRAME)
                except ida_hexrays.DecompilationFailure:
                    log_print(f'internal error in: {idaapi.get_func(ea)}')
                    continue

                fn : idaapi.func_t = idaapi.get_func(ea)
                fn_proto: idaapi.ida_typeinf.tinfo_t = fn.get_prototype()
                ret_tp = ''
                if fn_proto is None:
                    log_print(f'[WARNING] can not retrieve return type of \'{func_name_dm}\'')
                else:
                    ret_tp = fn_proto.get_rettype()

                f.write(f"// prototype: {ret_tp} {func_name_dm}\n")
                f.write(str(cfunc) + "\n\n")
                log_print(f'export: {func_name_dm}')

        log_print(f'file saved: {out_filename}')

if __name__ == '__main__':

    # retrieve pseudocode output directory
    script_path = os.path.abspath(__file__)
    pseudocode_out_dir = os.path.join(os.path.dirname(script_path), '..', '_pseudo')

    export('^(?!std::)\w.+', f'{pseudocode_out_dir}/NvFlexDebugD3D_x64.cpp')
    # export('(^Wind_Waves_FFT_Simulation_CPU_Impl::[^`].*)|(^Wind_Waves_FFT_Simulation::[^`].*)', f'{pseudocode_out_dir}/_Wind_Waves_FFT_Simulation_CPU_Impl.cpp')
    # export('^(GFSDK_|WaveWorks_Internal|handle_b_error|handle_ww_error).+', f'{pseudocode_out_dir}/_Entrypoints.cpp')
    # export('^Local_Waves_FFT_Simulation_Compute_Impl::[^`].*', f'{pseudocode_out_dir}/_Local_Waves_FFT_Simulation_Compute_Impl.cpp')
    # export('^(Local_Waves_FFT_Simulation|Local_Waves_FFT_Simulation_CPU_Impl)::[^`].*', f'{pseudocode_out_dir}/_Local_Waves_FFT_Simulation_CPU_Impl.cpp')
    # export('^Local_Waves_Simulation::[^`].*', f'{pseudocode_out_dir}/_Local_Waves_Simulation.cpp')
    # export('^Wind_Waves_FFT_Simulation_Compute_Impl::[^`].*', f'{pseudocode_out_dir}/_Wind_Waves_FFT_Simulation_Compute_Impl.cpp')
    # export('^Wind_Waves_Simulation_Manager_Compute_Impl::[^`].*', f'{pseudocode_out_dir}/_Wind_Waves_Simulation_Manager_Compute_Impl.cpp')
    # export('^Wind_Waves_Simulation::[^`].*', f'{pseudocode_out_dir}/_Wind_Waves_Simulation.cpp')
    # export('(^ThreadPool::[^`].*)|(^ThreadSafeQueue.+)', f'{pseudocode_out_dir}/_ThreadPool.h')
    # export('(^Quadtree::[^`].*)|(^isLeaf.*)|(^compareQuadNodesForFrontToBackSorting.*)', f'{pseudocode_out_dir}/_Quadtree.cpp')
    # export('^Simulation_Util::.+', f'{pseudocode_out_dir}/_Simulation_Util.cpp')