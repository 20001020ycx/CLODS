cmake_minimum_required(VERSION 3.4.3)
project(StaticAnalysis)

# The following two settings are for MacOS.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# set(CMAKE_BUILD_TYPE Debug)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)
endif()

#set(CMAKE_CXX_FLAGS "-Wall -Wextra")
set(CMAKE_CXX_FLAGS_DEBUG "-g")
set(CMAKE_CXX_FLAGS_RELEASE "-Ofast")

find_package(LLVM REQUIRED CONFIG)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION}")
message(STATUS "Using LLVMConfig.cmake in: ${LLVM_DIR}")

find_package(Z3 REQUIRED CONFIG)
message(STATUS "Z3_FOUND: ${Z3_FOUND}")
message(STATUS "Found Z3 ${Z3_VERSION_STRING}")
message(STATUS "Z3_DIR: ${Z3_DIR}")
message(STATUS "Z3_LIBDIR: ${Z3_LIBRARIES}")
message(STATUS "Z3_FLAG: ${Z3_COMPONENT_CXX_FLAGS}")

# Find the Protobuf package
find_package(protobuf REQUIRED CONFIG)
message(STATUS "Protobuf_FOUND: ${Protobuf_FOUND}")
message(STATUS "Protobuf_DIR: ${Protobuf_DIR}")
message(STATUS "Protobuf_INCLUDE_DIR: ${Protobuf_INCLUDE_DIR}")

find_package(gRPC REQUIRED)
message(STATUS "gRPC_FOUND: ${gRPC_LIBRARIES}")
message(STATUS "gRPC_DIR: ${gRPC_DIR}")
message(STATUS "gRPC_INCLUDE_DIR: ${gRPC_INCLUDE_DIR}")

#I don't know why protocbuf must enforce this option
add_compile_options(-frtti)

list(APPEND CMAKE_MODULE_PATH ${LLVM_DIR})
include(ChooseMSVCCRT)

include(AddLLVM)
include(HandleLLVMOptions)
include_directories("${LLVM_INCLUDE_DIR}")
include_directories("${Z3_CXX_INCLUDE_DIRS}")
include_directories("${CMAKE_INCLUDE_PATH}")
message(STATUS "cmake include path: ${CMAKE_INCLUDE_PATH}")
link_directories("${LLVM_LIBRARY_DIRS}")
separate_arguments(LLVM_DEFINITIONS_LIST NATIVE_COMMAND ${LLVM_DEFINITIONS})
add_definitions("${LLVM_DEFINITIONS}")

link_directories("${LLVM_LIBRARY_DIR}")

include_directories(BEFORE include)
add_subdirectory(lib)
add_executable(static-analysis StaticAnalysis.cpp)


llvm_map_components_to_libnames(llvm_libs support core irreader passes)

target_link_libraries(static-analysis ${llvm_libs} grpc++ gRPC::grpc++_reflection protobuf::libprotobuf Helloworld ControlDependency DataDependency EventGraph CallerMapGenPass Utility DeleteNullPtrException Optimization Compare ProtocBuf )

