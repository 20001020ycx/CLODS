; RUN: opt -passes='SourceLocation' -S < %s | FileCheck %s
; ModuleID = 'f3.bc'
source_filename = "NullPtrExceptionNoCatch.main"

@"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#0" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#1" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#2" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#3" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#4" = external addrspace(1) global ptr addrspace(1)

; Function Attrs: noinline noredzone
define { i64 } @NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a(i64 %0, ptr addrspace(1) %1) #0 gc "compressed-pointer" personality ptr @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4 {
B0:
  call void (i64, i32, ...) @llvm.experimental.stackmap(i64 31383, i32 0)
  %2 = inttoptr i64 %0 to ptr
  %3 = getelementptr i8, ptr %2, i64 8
  %4 = bitcast ptr %3 to ptr
  %5 = load i64, ptr %4, align 4
  %6 = call i64 @llvm.read_register.i64(metadata !0)
  %7 = icmp ult i64 %5, %6
  br i1 %7, label %B1, label %B27, !prof !1

B1:                                               ; preds = %B0
  %8 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#0", align 8
  %9 = ptrtoint ptr addrspace(1) %8 to i64
  %10 = inttoptr i64 %0 to ptr
  %11 = getelementptr i8, ptr %10, i64 40
  %12 = bitcast ptr %11 to ptr
  %13 = load i64, ptr %12, align 4
  %14 = inttoptr i64 %0 to ptr
  %15 = getelementptr i8, ptr %14, i64 32
  %16 = bitcast ptr %15 to ptr
  %17 = load i64, ptr %16, align 4
  %18 = add i64 %13, 224
  %19 = icmp ult i64 %17, %18
  br i1 %19, label %B2, label %B3, !prof !2

B2:                                               ; preds = %B1
  %20 = call { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64 %0, i64 %9, i64 224) #5
  %21 = extractvalue { i64, ptr addrspace(1) } %20, 0
  %22 = extractvalue { i64, ptr addrspace(1) } %20, 1
  br label %B7

B3:                                               ; preds = %B1
  %23 = bitcast ptr %11 to ptr
  store i64 %18, ptr %23, align 4
  %24 = inttoptr i64 %13 to ptr
  %25 = getelementptr i8, ptr %24, i64 480
  call void @llvm.prefetch.p0(ptr %25, i32 1, i32 0, i32 1)
  %26 = inttoptr i64 %13 to ptr
  %27 = getelementptr i8, ptr %26, i64 0
  %28 = bitcast ptr %27 to ptr
  store i64 %9, ptr %28, align 4
  %29 = inttoptr i64 %13 to ptr
  %30 = getelementptr i8, ptr %29, i64 8
  %31 = bitcast ptr %30 to ptr
  store i32 0, ptr %31, align 4
  %32 = inttoptr i64 %13 to ptr
  %33 = getelementptr i8, ptr %32, i64 12
  %34 = bitcast ptr %33 to ptr
  store i32 0, ptr %34, align 4
  br label %B4

B4:                                               ; preds = %B5, %B3
  %35 = phi i64 [ %0, %B3 ], [ %35, %B5 ]
  %36 = phi i64 [ 16, %B3 ], [ %41, %B5 ]
  %37 = icmp ult i64 %36, 224
  br i1 %37, label %B5, label %B6, !prof !3

B5:                                               ; preds = %B4
  %38 = inttoptr i64 %13 to ptr
  %39 = getelementptr i8, ptr %38, i64 %36
  %40 = bitcast ptr %39 to ptr
  store i64 0, ptr %40, align 4
  %41 = add i64 %36, 8
  br label %B4

B6:                                               ; preds = %B4
  %42 = call ptr addrspace(1) @__llvm_int_to_object(i64 %13)
  br label %B7

B7:                                               ; preds = %B6, %B2
  %43 = phi i64 [ %21, %B2 ], [ %35, %B6 ]
  %44 = phi ptr addrspace(1) [ %22, %B2 ], [ %42, %B6 ]
  fence seq_cst
  %45 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#1", align 8
  %46 = call { i64 } @Scanner_constructor_3f86ab6c173e6c247c9ae271c3c2586c89665361(i64 %43, ptr addrspace(1) %44, ptr addrspace(1) %45) #6
  %47 = extractvalue { i64 } %46, 0
  br label %B8

B8:                                               ; preds = %B7
  %48 = call { i64, ptr addrspace(1) } @Scanner_nextLine_de0f6fd26bac70c51c277bba341e6d8607054963(i64 %47, ptr addrspace(1) %44) #7
  %49 = extractvalue { i64, ptr addrspace(1) } %48, 0
  %50 = extractvalue { i64, ptr addrspace(1) } %48, 1
  br label %B9

B9:                                               ; preds = %B8
  %51 = icmp eq ptr addrspace(1) %50, null
  br i1 %51, label %B10, label %B11, !prof !4

; CHECK_NOT: .*call.*ImplicitExceptions_throwNewNullPointerException
B10:                                              ; preds = %B9
  %52 = call { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64 %49) #8
  %53 = extractvalue { i64 } %52, 0
  unreachable

B11:                                              ; preds = %B9
  %54 = call { i64, i32 } @String_length_c8bec93b04b501e5e0144a1d586f117cb490caca(i64 %49, ptr addrspace(1) %50) #9
  %55 = extractvalue { i64, i32 } %54, 0
  %56 = extractvalue { i64, i32 } %54, 1
  br label %B12

B12:                                              ; preds = %B11
  %57 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#2", align 8
  %58 = ptrtoint ptr addrspace(1) %57 to i64
  %59 = bitcast ptr %11 to ptr
  %60 = load i64, ptr %59, align 4
  %61 = bitcast ptr %15 to ptr
  %62 = load i64, ptr %61, align 4
  %63 = add i64 %60, 40
  %64 = icmp ult i64 %62, %63
  br i1 %64, label %B13, label %B14, !prof !2

B13:                                              ; preds = %B12
  %65 = call { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64 %55, i64 %58, i64 40) #10
  %66 = extractvalue { i64, ptr addrspace(1) } %65, 0
  %67 = extractvalue { i64, ptr addrspace(1) } %65, 1
  br label %B15

B14:                                              ; preds = %B12
  %68 = bitcast ptr %11 to ptr
  store i64 %63, ptr %68, align 4
  %69 = inttoptr i64 %60 to ptr
  %70 = getelementptr i8, ptr %69, i64 296
  call void @llvm.prefetch.p0(ptr %70, i32 1, i32 0, i32 1)
  %71 = inttoptr i64 %60 to ptr
  %72 = getelementptr i8, ptr %71, i64 0
  %73 = bitcast ptr %72 to ptr
  store i64 %58, ptr %73, align 4
  %74 = inttoptr i64 %60 to ptr
  %75 = getelementptr i8, ptr %74, i64 8
  %76 = bitcast ptr %75 to ptr
  store i32 0, ptr %76, align 4
  %77 = inttoptr i64 %60 to ptr
  %78 = getelementptr i8, ptr %77, i64 12
  %79 = bitcast ptr %78 to ptr
  store i32 0, ptr %79, align 4
  %80 = inttoptr i64 %60 to ptr
  %81 = getelementptr i8, ptr %80, i64 16
  %82 = bitcast ptr %81 to ptr
  store i64 0, ptr %82, align 4
  %83 = inttoptr i64 %60 to ptr
  %84 = getelementptr i8, ptr %83, i64 24
  %85 = bitcast ptr %84 to ptr
  store i64 0, ptr %85, align 4
  %86 = inttoptr i64 %60 to ptr
  %87 = getelementptr i8, ptr %86, i64 32
  %88 = bitcast ptr %87 to ptr
  store i64 0, ptr %88, align 4
  %89 = call ptr addrspace(1) @__llvm_int_to_object(i64 %60)
  br label %B15

B15:                                              ; preds = %B14, %B13
  %90 = phi i64 [ %66, %B13 ], [ %55, %B14 ]
  %91 = phi ptr addrspace(1) [ %67, %B13 ], [ %89, %B14 ]
  fence seq_cst
  %92 = add i32 %56, 123456
  %93 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#3", align 8
  %94 = call { i64 } @StringBuilder_constructor_15fe70429bc651383130f60cc6f49aafc708247c(i64 %90, ptr addrspace(1) %91) #11
  %95 = extractvalue { i64 } %94, 0
  br label %B16

B16:                                              ; preds = %B15
  %96 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionNoCatch_main_7b74127e402a41423535ac036a240eecbf0cca4a#4", align 8
  %97 = call { i64, ptr addrspace(1) } @StringBuilder_append_bb02350bf43a0b629fd161889a9183049f6dd0a8(i64 %95, ptr addrspace(1) %91, ptr addrspace(1) %96) #12
  %98 = extractvalue { i64, ptr addrspace(1) } %97, 0
  %99 = extractvalue { i64, ptr addrspace(1) } %97, 1
  br label %B17

B17:                                              ; preds = %B16
  %100 = icmp eq ptr addrspace(1) %99, null
  br i1 %100, label %B18, label %B19, !prof !4

B18:                                              ; preds = %B17
  %101 = call { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64 %98) #13
  %102 = extractvalue { i64 } %101, 0
  unreachable

B19:                                              ; preds = %B17
  %103 = call { i64, ptr addrspace(1) } @StringBuilder_append_4480f123c6e4bef4001c7d565e9c46895d0afb64(i64 %98, ptr addrspace(1) %99, i32 %92) #14
  %104 = extractvalue { i64, ptr addrspace(1) } %103, 0
  %105 = extractvalue { i64, ptr addrspace(1) } %103, 1
  br label %B20

B20:                                              ; preds = %B19
  %106 = icmp eq ptr addrspace(1) %105, null
  br i1 %106, label %B21, label %B22, !prof !4

B21:                                              ; preds = %B20
  %107 = call { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64 %104) #15
  %108 = extractvalue { i64 } %107, 0
  unreachable

B22:                                              ; preds = %B20
  %109 = call { i64, ptr addrspace(1) } @StringBuilder_toString_fff5cf8f9838ca54b87be4fc46d795a7c0e01bd4(i64 %104, ptr addrspace(1) %105) #16
  %110 = extractvalue { i64, ptr addrspace(1) } %109, 0
  %111 = extractvalue { i64, ptr addrspace(1) } %109, 1
  br label %B23

B23:                                              ; preds = %B22
  %112 = call { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64 %110, ptr addrspace(1) %93, ptr addrspace(1) %111) #17
  %113 = extractvalue { i64 } %112, 0
  br label %B24

B24:                                              ; preds = %B23
  %114 = inttoptr i64 %113 to ptr
  %115 = getelementptr i8, ptr %114, i32 16
  %116 = bitcast ptr %115 to ptr
  %117 = load i32, ptr %116, align 4
  %118 = sub i32 %117, 1
  %119 = bitcast ptr %115 to ptr
  store i32 %118, ptr %119, align 4
  %120 = icmp sle i32 %118, 0
  br i1 %120, label %B25, label %B26, !prof !5

B25:                                              ; preds = %B24
  %121 = call { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64 %113) #18
  %122 = extractvalue { i64 } %121, 0
  %123 = insertvalue { i64 } zeroinitializer, i64 %122, 0
  ret { i64 } %123

B26:                                              ; preds = %B24
  %124 = insertvalue { i64 } zeroinitializer, i64 %113, 0
  ret { i64 } %124

B27:                                              ; preds = %B0
  %125 = call { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64 %0) #19
  %126 = extractvalue { i64 } %125, 0
  unreachable
}

declare { i64, i32 } @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4(i32, i32, i64, i64, i64)

; Function Attrs: nocallback nofree nosync willreturn
declare void @llvm.experimental.stackmap(i64, i32, ...) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(read)
declare i64 @llvm.read_register.i64(metadata) #2

declare { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64, i64, i64)

; Function Attrs: alwaysinline
define linkonce ptr addrspace(1) @__llvm_int_to_object(i64 %0) #3 {
main:
  %1 = inttoptr i64 %0 to ptr addrspace(1)
  ret ptr addrspace(1) %1
}

declare { i64 } @Scanner_constructor_3f86ab6c173e6c247c9ae271c3c2586c89665361(i64, ptr addrspace(1), ptr addrspace(1))

declare { i64, ptr addrspace(1) } @Scanner_nextLine_de0f6fd26bac70c51c277bba341e6d8607054963(i64, ptr addrspace(1))

declare { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64)

declare { i64, i32 } @String_length_c8bec93b04b501e5e0144a1d586f117cb490caca(i64, ptr addrspace(1))

declare { i64 } @StringBuilder_constructor_15fe70429bc651383130f60cc6f49aafc708247c(i64, ptr addrspace(1))

declare { i64, ptr addrspace(1) } @StringBuilder_append_bb02350bf43a0b629fd161889a9183049f6dd0a8(i64, ptr addrspace(1), ptr addrspace(1))

declare { i64, ptr addrspace(1) } @StringBuilder_append_4480f123c6e4bef4001c7d565e9c46895d0afb64(i64, ptr addrspace(1), i32)

declare { i64, ptr addrspace(1) } @StringBuilder_toString_fff5cf8f9838ca54b87be4fc46d795a7c0e01bd4(i64, ptr addrspace(1))

declare { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64, ptr addrspace(1), ptr addrspace(1))

declare { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64)

declare { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64)

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @llvm.prefetch.p0(ptr nocapture readonly, i32 immarg, i32 immarg, i32 immarg) #4


!0 = !{!"rsp\00"}
!1 = !{!"branch_weights", i32 2147481499, i32 2147}
!2 = !{!"branch_weights", i32 21474836, i32 2126008810}
!3 = !{!"branch_weights", i32 1073741823, i32 1073741823}
!4 = !{!"branch_weights", i32 2147, i32 2147481499}
!5 = !{!"branch_weights", i32 2147483, i32 2145336163}
