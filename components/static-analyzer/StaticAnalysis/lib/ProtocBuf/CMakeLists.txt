set(LLVM_LINK_COMPONENTS
  Demangle
)

llvm_map_components_to_libnames(REQ_LLVM_LIBRARIES
  core analysis support passes
)

include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# utility function to extract specific components or properties from a file path
# or filename.
# ABSOLUTE means to retrieves the absolute path of the file
get_filename_component(instrumentation_proto "bm_protobuf/instrumentation.proto" ABSOLUTE)
# PATH means the path to the actual file itself
# This is used to locate the instrumentation.proto itself
get_filename_component(instrumentation_proto_path "${instrumentation_proto}" PATH)
if  (NOT EXISTS "${instrumentation_proto}")
  message(FATAL_ERROR "Please pull instrumentation submodule recursively correctly")
endif()

# Generated sources
set(instrumentation_proto_srcs "${CMAKE_CURRENT_SOURCE_DIR}/instrumentation.pb.cc")
set(instrumentation_proto_hdrs "${CMAKE_CURRENT_SOURCE_DIR}/instrumentation.pb.h")
set(instrumentation_grpc_srcs "${CMAKE_CURRENT_SOURCE_DIR}/instrumentation.grpc.pb.cc")
set(instrumentation_grpc_hdrs "${CMAKE_CURRENT_SOURCE_DIR}/instrumentation.grpc.pb.h")

# find executable binary in the PATH variable 
find_program(_PROTOBUF_PROTOC protoc)
find_program(_GRPC_CPP_PLUGIN_EXECUTABLE grpc_cpp_plugin)

if ((NOT _PROTOBUF_PROTOC) OR (NOT _GRPC_CPP_PLUGIN_EXECUTABLE))
  message(FATAL_ERROR "Required program protoc and grpc_cpp_plugin not found in PATH")
endif()

message("protobuf binary is: ${_PROTOBUF_PROTOC}")
message("grpc binary is: ${_GRPC_CPP_PLUGIN_EXECUTABLE}")
# compile instrumentation.proto file and generate required header and cc files
add_custom_command(
    OUTPUT "${instrumentation_proto_srcs}" "${instrumentation_proto_hdrs}" "${instrumentation_grpc_srcs}" "${instrumentation_grpc_hdrs}"
    COMMAND ${_PROTOBUF_PROTOC}
      ARGS --grpc_out "${CMAKE_CURRENT_SOURCE_DIR}"
        --cpp_out "${CMAKE_CURRENT_SOURCE_DIR}"
        --plugin=protoc-gen-grpc="${_GRPC_CPP_PLUGIN_EXECUTABLE}"
        -I "${instrumentation_proto_path}"
        -I "${CMAKE_INCLUDE_PATH}"
        "${instrumentation_proto}"
    DEPENDS "${instrumentation_proto}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
)

add_library(ProtocBuf OBJECT 
    ProtocBuf.cpp  
    ${instrumentation_grpc_srcs}
    ${instrumentation_grpc_hdrs}
    ${instrumentation_proto_srcs}
    ${instrumentation_proto_hdrs}
)



