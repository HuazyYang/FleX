cmake_policy(SET CMP0121 NEW)

find_program(FXC_COMPILER "fxc" REQUIRED)

if(NOT TARGET ShaderTool)
add_executable(ShaderTool 
    "${CMAKE_CURRENT_LIST_DIR}/ShaderTool/ShaderTool.c"
    "${CMAKE_CURRENT_LIST_DIR}/ShaderTool/pipeex.c"
)
target_compile_definitions(ShaderTool PRIVATE "WIN32_LEAN_AND_MEAN" "UNICODE")
set_target_properties(ShaderTool PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded"
    # LINK_LIBRARIES "vld"
    )
endif()

function(nvflow_add_shader_object_headers)
    set(options OUTPUT_NAME_USE_ENTRY)
    set(oneValueArgs TARGET SHADER_PROFILE CONFIG_FILE OUTPUT_DIRECTORY)
    set(multiValueArgs INCLUDE_DIRECTORIES EXTRA_FLAGS)

    cmake_parse_arguments("nvflow" "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    # Set ShaderTool program path
    set(SHADERTOOL_PROG "$<TARGET_FILE:ShaderTool>")

    # Sanity check
    if(NOT nvflow_TARGET OR NOT nvflow_CONFIG_FILE)
        message(FATAL_ERROR "nvflow_add_shader_object_headers: <TARGET> and <CONFIG_FILE> must be specified")
    endif()

    if(NOT nvflow_SHADER_PROFILE)
        set(nvflow_SHADER_PROFILE "5_0") # Default shader profile
    endif()

    if(NOT nvflow_OUTPUT_DIRECTORY)
        set(nvflow_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}) # Default output directory
    endif()

    # transform config file path
    cmake_path(ABSOLUTE_PATH nvflow_CONFIG_FILE NORMALIZE OUTPUT_VARIABLE config_file_path)
    cmake_path(GET config_file_path PARENT_PATH config_file_dir)

    # # config stage
    # append config dependency
    set_property(
        DIRECTORY
        APPEND
        PROPERTY CMAKE_CONFIGURE_DEPENDS
        ${config_file_path}
    )

    # generate extra options
    set(extra_options ${nvflow_EXTRA_FLAGS})

    # append additional include directories
    foreach(dir ${nvflow_INCLUDE_DIRECTORIES})
        cmake_path(ABSOLUTE_PATH dir NORMALIZE OUTPUT_VARIABLE dir)
        list(APPEND extra_options "-I" "${dir}")
    endforeach(dir ${nvflow_INCLUDE_DIRECTORIES})

    # # build stage

    # Make output directory if not present
    set(objects_output_dir ${nvflow_OUTPUT_DIRECTORY})
    add_custom_command(
        OUTPUT ${objects_output_dir}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${objects_output_dir}
        COMMAND_EXPAND_LISTS
    )

    # Make intermediate directory
    set(intermediate_dir "${CMAKE_CURRENT_BINARY_DIR}/__shadertools_${nvflow_TARGET}")
    add_custom_command(
        OUTPUT ${intermediate_dir}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${intermediate_dir}
        COMMAND_EXPAND_LISTS
    )

    file(STRINGS ${nvflow_CONFIG_FILE} shader_cfg_lines REGEX "^[ \t\r\n]*[^#]+$")

    set(output_file_list "")
    set(entry_file_list "")

    foreach(cmd ${shader_cfg_lines})
        separate_arguments(cmd_line NATIVE_COMMAND ${cmd})

        # Resolve input file path and re-write command
        list(GET cmd_line 0 entry_file_name)
        list(REMOVE_AT cmd_line 0) # remove entry file entry and re-arrange it later
        cmake_path(GET entry_file_name EXTENSION LAST_ONLY entry_file_ext)
        cmake_path(ABSOLUTE_PATH entry_file_name BASE_DIRECTORY ${config_file_dir} OUTPUT_VARIABLE entry_file_path)
        cmake_path(GET entry_file_path PARENT_PATH entry_file_dir)
        cmake_path(RELATIVE_PATH entry_file_dir BASE_DIRECTORY ${config_file_dir} OUTPUT_VARIABLE entry_file_dir_rel_config)

        list(LENGTH cmd_line cmd_line_length)

        # Add -nologo option if necessary
        list(FIND cmd_line "-nologo" nologo_index)
        if(${nologo_index} STREQUAL -1)
            list(APPEND cmd_line "-nologo")
        endif()

        # Re-target shader profile
        list(FIND cmd_line "-T" target_index)
        MATH(EXPR target_index "${target_index}+1")

        if(${target_index} GREATER_EQUAL 1 AND ${target_index} LESS_EQUAL ${cmd_line_length})
            list(GET cmd_line ${target_index} target_profile)
            set(target_profile "${target_profile}_${nvflow_SHADER_PROFILE}")
            list(REMOVE_AT cmd_line ${target_index})
            list(INSERT cmd_line ${target_index} ${target_profile})
        endif()

        # Specify output file path
        set(output_file_path "")
        set(output_dir "")
        set(output_file_name "")

        # Retrieve output file name
        if(${nvflow_OUTPUT_NAME_USE_ENTRY})
            list(FIND cmd_line "-E" target_index)
            MATH(EXPR target_index "${target_index}+1")
            if(${target_index} GREATER_EQUAL 1 AND ${target_index} LESS ${cmd_line_length})
                list(GET cmd_line ${target_index} output_file_name)
            else()
                message(FATAL_ERROR "-E <entry> missing in \"${cmd}\"")
            endif()

            if(output_file_name STREQUAL "")
                message(FATAL_ERROR "nvflow_add_shader_object_headers: \"${cmd_line}\" does not have a entry function")
            endif()

            cmake_path(APPEND objects_output_dir ${entry_file_dir_rel_config} OUTPUT_VARIABLE output_dir)

            set(output_file_name "${output_file_name}${entry_file_ext}.h")
            set(output_file_path "${output_dir}/${output_file_name}")
        else()
            set(output_file_name "${entry_file_name}.h")
            set(output_file_path "${objects_output_dir}/${output_file_name}")
        endif()

        list(APPEND output_file_list ${output_file_path})
        list(APPEND cmd_line "-Fh;${output_file_path}")

        #[[
        list(APPEND cmd_line "$<$<OR:$<CONFIG:Debug>,$<CONFIG:RelWithDebInfo>>:/Zi>")
        list(APPEND cmd_line "$<$<OR:$<CONFIG:Debug>,$<CONFIG:RelWithDebInfo>>:/Od>")
        ]]

        # insert extra options at front of command line
        # Note that extra options may contain -D<macro> which must have highest priority.
        list(LENGTH extra_options  extra_options_length)
        if(NOT ${extra_options_length} EQUAL 0)
            list(INSERT cmd_line 0 ${extra_options})
        endif()

        # Re-arrange entry file to last
        list(APPEND cmd_line ${entry_file_path})
        list(APPEND entry_file_list ${entry_file_path})

        # Make depfile intermediate directory
        cmake_path(APPEND intermediate_dir ${entry_file_dir_rel_config} OUTPUT_VARIABLE depfile_output_dir)
        set(depfile_output_path "${depfile_output_dir}/${output_file_name}.depends")

        string(REPLACE ";" "\\;" cmd_line "${cmd_line}")

        add_custom_command(OUTPUT ${output_file_path}
            BYPRODUCTS ${depfile_output_path}
            COMMAND ${SHADERTOOL_PROG} "--fxc=${FXC_COMPILER}" "--options=${cmd_line}" "--depfile=${depfile_output_path}"
            WORKING_DIRECTORY ${entry_file_dir}
            DEPENDS ${entry_file_path} ${objects_output_dir} ${intermediate_dir}
            DEPFILE ${depfile_output_path}
            COMMAND_EXPAND_LISTS
        )
    endforeach(cmd shader_cfg_lines)

    add_custom_target(
        ${nvflow_TARGET}
        DEPENDS ${output_file_list}
        SOURCES ${entry_file_list}
    )
    add_dependencies(${nvflow_TARGET} ShaderTool)

    # Set a header include directory path in parent scope
    define_property(TARGET PROPERTY OBJECT_HEADER_PUBLIC_DIR
        BRIEF_DOCS "Shader object header file include directory"
        FULL_DOCS "Shader object header file include directory")
    define_property(TARGET PROPERTY OBJECT_HEADER_FILES
        BRIEF_DOCS "Shader object header file list"
        FULL_DOCS "Shader object header file list")
    set_property(TARGET ${nvflow_TARGET}
        PROPERTY
        OBJECT_HEADER_OUTPUT_DIR ${objects_output_dir}
    )
    set_property(TARGET ${nvflow_TARGET}
        PROPERTY
        OBJECT_HEADER_FILES ${output_file_list}
    )
endfunction(nvflow_add_shader_object_headers)