if(NVFLEX_USE_MICROSOFT_VLD)
    include(../cmake/FindVLD.cmake)
    set(NVFLEX__USE_MICROSOFT_VLD 1)
else()
    set(NVFLEX__USE_MICROSOFT_VLD 0)
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

nvflow_add_shader_object_headers(
    TARGET NvFlexShaders
    SHADER_PROFILE 5_0
    CONFIG_FILE "shaders/Shaders.cfg"
    OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/$<CONFIG>/__shader_objs"
    OUTPUT_NAME_USE_ENTRY
    INCLUDE_DIRECTORIES
    "../external/nvapi/include"
    "../external/ags_lib/hlsl"
)
get_target_property(NvFlexShaders_SHADER_HEADER_OUTPUT_DIR NvFlexShaders OBJECT_HEADER_OUTPUT_DIR)
get_target_property(NvFlexShaders_OBJECT_HEADER_FILES NvFlexShaders OBJECT_HEADER_FILES)

file(GLOB NvFlexDXBCBinaryFiles "dxbc/*.txt")
cmrc_add_resource_library(
    NvFlexDXBCBinaryLib
    WHENCE dxbc
    NAMESPACE nvflex
    ${NvFlexDXBCBinaryFiles}
)

file(GLOB Flex_PRIVATE_HEADERS "private/*.h")
file(GLOB Flex_SOURCES "*.cpp" "*.c")

add_library(NvFlexRev SHARED
    ${Flex_PRIVATE_HEADERS}
    ${Flex_SOURCES}
)
target_compile_definitions(NvFlexRev PRIVATE "NOMINMAX=1" "_CRT_SECURE_NO_WARNINGS" "NVFLEX__USE_MICROSOFT_VLD=${NVFLEX__USE_MICROSOFT_VLD}")
set_target_properties(
    NvFlexRev PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin/$<CONFIG>"
    PDB_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin/$<CONFIG>"
)
target_include_directories(
    NvFlexRev
    PUBLIC "${CMAKE_SOURCE_DIR}/include"
    PRIVATE "private" "${NvFlexShaders_SHADER_HEADER_OUTPUT_DIR}"
)
target_link_libraries(NvFlexRev PRIVATE "dxguid.lib" NVTX NVAPI AGS NvFlexDXBCBinaryLib "$<${NVFLEX__USE_MICROSOFT_VLD}:vld>")
add_dependencies(NvFlexRev NvFlexShaders)



