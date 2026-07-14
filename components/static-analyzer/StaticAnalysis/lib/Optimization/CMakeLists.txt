set(LLVM_LINK_COMPONENTS
  Demangle
)

llvm_map_components_to_libnames(REQ_LLVM_LIBRARIES
  core analysis support passes
)

add_llvm_library(Optimization OBJECT 
    Optimization.cpp 
)

find_package(Z3 REQUIRED CONFIG)

target_include_directories(Optimization PUBLIC ${Z3_CXX_INCLUDE_DIRS})
target_link_libraries(Optimization PUBLIC ${Z3_LIBRARIES})

target_compile_options(Optimization PUBLIC ${Z3_COMPONENT_CXX_FLAGS})