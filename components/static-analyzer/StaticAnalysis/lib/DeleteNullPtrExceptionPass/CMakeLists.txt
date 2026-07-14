set(LLVM_LINK_COMPONENTS
  Demangle
)

llvm_map_components_to_libnames(REQ_LLVM_LIBRARIES
  core analysis support passes
)

add_llvm_library(DeleteNullPtrException OBJECT 
  DeleteNullPtrException.cpp
)