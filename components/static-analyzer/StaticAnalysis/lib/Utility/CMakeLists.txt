set(LLVM_LINK_COMPONENTS
  Demangle
)

llvm_map_components_to_libnames(REQ_LLVM_LIBRARIES
  core analysis support passes
)

add_compile_options(-fexceptions)

add_llvm_library(Utility OBJECT 
  Utility.cpp InstrumentationPlan.cpp  
)

# instrumentation plan requires header file generated from .proto file
target_include_directories(Utility PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/../ProtocBuf)
