set(LLVM_LINK_COMPONENTS
  Demangle
)

add_llvm_library(Compare OBJECT 
  Compare.cpp Log.cpp Trace.cpp Event.cpp PrefixTree.cpp
)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

target_link_libraries(Compare)
