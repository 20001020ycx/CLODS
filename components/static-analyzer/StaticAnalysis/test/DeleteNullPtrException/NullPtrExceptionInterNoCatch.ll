; ModuleID = 'NullPtrExceptionInterNoCatch.ll'
source_filename = "llvm-link"

@"constant_NullPtrExceptionInterNoCatch_interNullPtrException_7110e26417e50866f3040c69099957d348a42bd8#0" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInterNoCatch_interNullPtrException_7110e26417e50866f3040c69099957d348a42bd8#1" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInterNoCatch_main_110bc46dad68ea45a6a3b5264a8cc092ec172d25#0" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInterNoCatch_main_110bc46dad68ea45a6a3b5264a8cc092ec172d25#1" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInterNoCatch_main_110bc46dad68ea45a6a3b5264a8cc092ec172d25#2" = external addrspace(1) global ptr addrspace(1)

; Function Attrs: noinline noredzone
define { i64, i32 } @NullPtrExceptionInterNoCatch_interNullPtrException_7110e26417e50866f3040c69099957d348a42bd8(i64 %0) #0 gc "compressed-pointer" personality ptr @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4 {
B0:
  call void (i64, i32, ...) @llvm.experimental.stackmap(i64 56549, i32 0)
  %1 = inttoptr i64 %0 to ptr
  %2 = getelementptr i8, ptr %1, i64 8
  %3 = bitcast ptr %2 to ptr
  %4 = load i64, ptr %3, align 4
  %5 = call i64 @llvm.read_register.i64(metadata !0)
  %6 = icmp ult i64 %4, %5
  br i1 %6, label %B1, label %B15, !prof !1

B1:                                               ; preds = %B0
  %7 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInterNoCatch_interNullPtrException_7110e26417e50866f3040c69099957d348a42bd8#0", align 8
  %8 = ptrtoint ptr addrspace(1) %7 to i64
  %9 = inttoptr i64 %0 to ptr
  %10 = getelementptr i8, ptr %9, i64 40
  %11 = bitcast ptr %10 to ptr
  %12 = load i64, ptr %11, align 4
  %13 = inttoptr i64 %0 to ptr
  %14 = getelementptr i8, ptr %13, i64 32
  %15 = bitcast ptr %14 to ptr
  %16 = load i64, ptr %15, align 4
  %17 = add i64 %12, 224
  %18 = icmp ult i64 %16, %17
  br i1 %18, label %B2, label %B3, !prof !2

B2:                                               ; preds = %B1
  %19 = call { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64 %0, i64 %8, i64 224) #5
  %20 = extractvalue { i64, ptr addrspace(1) } %19, 0
  %21 = extractvalue { i64, ptr addrspace(1) } %19, 1
  br label %B7

B3:                                               ; preds = %B1
  %22 = bitcast ptr %10 to ptr
  store i64 %17, ptr %22, align 4
  %23 = inttoptr i64 %12 to ptr
  %24 = getelementptr i8, ptr %23, i64 480
  call void @llvm.prefetch.p0(ptr %24, i32 1, i32 0, i32 1)
  %25 = inttoptr i64 %12 to ptr
  %26 = getelementptr i8, ptr %25, i64 0
  %27 = bitcast ptr %26 to ptr
  store i64 %8, ptr %27, align 4
  %28 = inttoptr i64 %12 to ptr
  %29 = getelementptr i8, ptr %28, i64 8
  %30 = bitcast ptr %29 to ptr
  store i32 0, ptr %30, align 4
  %31 = inttoptr i64 %12 to ptr
  %32 = getelementptr i8, ptr %31, i64 12
  %33 = bitcast ptr %32 to ptr
  store i32 0, ptr %33, align 4
  br label %B4

B4:                                               ; preds = %B5, %B3
  %34 = phi i64 [ %0, %B3 ], [ %34, %B5 ]
  %35 = phi i64 [ 16, %B3 ], [ %40, %B5 ]
  %36 = icmp ult i64 %35, 224
  br i1 %36, label %B5, label %B6, !prof !3

B5:                                               ; preds = %B4
  %37 = inttoptr i64 %12 to ptr
  %38 = getelementptr i8, ptr %37, i64 %35
  %39 = bitcast ptr %38 to ptr
  store i64 0, ptr %39, align 4
  %40 = add i64 %35, 8
  br label %B4

B6:                                               ; preds = %B4
  %41 = call ptr addrspace(1) @__llvm_int_to_object(i64 %12)
  br label %B7

B7:                                               ; preds = %B6, %B2
  %42 = phi i64 [ %20, %B2 ], [ %34, %B6 ]
  %43 = phi ptr addrspace(1) [ %21, %B2 ], [ %41, %B6 ]
  fence seq_cst
  %44 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInterNoCatch_interNullPtrException_7110e26417e50866f3040c69099957d348a42bd8#1", align 8
  %45 = call { i64 } @Scanner_constructor_3f86ab6c173e6c247c9ae271c3c2586c89665361(i64 %42, ptr addrspace(1) %43, ptr addrspace(1) %44) #6
  %46 = extractvalue { i64 } %45, 0
  br label %B8

B8:                                               ; preds = %B7
  %47 = call { i64, ptr addrspace(1) } @Scanner_nextLine_de0f6fd26bac70c51c277bba341e6d8607054963(i64 %46, ptr addrspace(1) %43) #7
  %48 = extractvalue { i64, ptr addrspace(1) } %47, 0
  %49 = extractvalue { i64, ptr addrspace(1) } %47, 1
  br label %B9

B9:                                               ; preds = %B8
  %50 = icmp eq ptr addrspace(1) %49, null
  br i1 %50, label %B10, label %B11, !prof !4

B10:                                              ; preds = %B9
  %51 = call { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64 %48) #8
  %52 = extractvalue { i64 } %51, 0
  unreachable

B11:                                              ; preds = %B9
  %53 = call { i64, i32 } @String_length_c8bec93b04b501e5e0144a1d586f117cb490caca(i64 %48, ptr addrspace(1) %49) #9
  %54 = extractvalue { i64, i32 } %53, 0
  %55 = extractvalue { i64, i32 } %53, 1
  br label %B12

B12:                                              ; preds = %B11
  %56 = add i32 %55, 123456
  %57 = inttoptr i64 %54 to ptr
  %58 = getelementptr i8, ptr %57, i32 16
  %59 = bitcast ptr %58 to ptr
  %60 = load i32, ptr %59, align 4
  %61 = sub i32 %60, 1
  %62 = bitcast ptr %58 to ptr
  store i32 %61, ptr %62, align 4
  %63 = icmp sle i32 %61, 0
  br i1 %63, label %B13, label %B14, !prof !5

B13:                                              ; preds = %B12
  %64 = call { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64 %54) #10
  %65 = extractvalue { i64 } %64, 0
  %66 = insertvalue { i64, i32 } zeroinitializer, i64 %65, 0
  %67 = insertvalue { i64, i32 } %66, i32 %56, 1
  ret { i64, i32 } %67

B14:                                              ; preds = %B12
  %68 = insertvalue { i64, i32 } zeroinitializer, i64 %54, 0
  %69 = insertvalue { i64, i32 } %68, i32 %56, 1
  ret { i64, i32 } %69

B15:                                              ; preds = %B0
  %70 = call { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64 %0) #11
  %71 = extractvalue { i64 } %70, 0
  unreachable
}

declare { i64, i32 } @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4(i32, i32, i64, i64, i64)

; Function Attrs: nocallback nofree nosync willreturn
declare void @llvm.experimental.stackmap(i64, i32, ...) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(read)
declare i64 @llvm.read_register.i64(metadata) #2

declare { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64, i64, i64)

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @llvm.prefetch.p0(ptr nocapture readonly, i32 immarg, i32 immarg, i32 immarg) #3

; Function Attrs: alwaysinline
define linkonce ptr addrspace(1) @__llvm_int_to_object(i64 %0) #4 {
main:
  %1 = inttoptr i64 %0 to ptr addrspace(1)
  ret ptr addrspace(1) %1
}

declare { i64 } @Scanner_constructor_3f86ab6c173e6c247c9ae271c3c2586c89665361(i64, ptr addrspace(1), ptr addrspace(1))

declare { i64, ptr addrspace(1) } @Scanner_nextLine_de0f6fd26bac70c51c277bba341e6d8607054963(i64, ptr addrspace(1))

declare { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64)

declare { i64, i32 } @String_length_c8bec93b04b501e5e0144a1d586f117cb490caca(i64, ptr addrspace(1))

declare { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64)

declare { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64)

; Function Attrs: noinline noredzone
define { i64 } @NullPtrExceptionInterNoCatch_main_110bc46dad68ea45a6a3b5264a8cc092ec172d25(i64 %0, ptr addrspace(1) %1) #0 gc "compressed-pointer" personality ptr @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4 {
B0:
  call void (i64, i32, ...) @llvm.experimental.stackmap(i64 56499, i32 0)
  %2 = inttoptr i64 %0 to ptr
  %3 = getelementptr i8, ptr %2, i64 8
  %4 = bitcast ptr %3 to ptr
  %5 = load i64, ptr %4, align 4
  %6 = call i64 @llvm.read_register.i64(metadata !0)
  %7 = icmp ult i64 %5, %6
  br i1 %7, label %B1, label %B17, !prof !1

B1:                                               ; preds = %B0
  %8 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInterNoCatch_main_110bc46dad68ea45a6a3b5264a8cc092ec172d25#0", align 8
  %9 = ptrtoint ptr addrspace(1) %8 to i64
  %10 = inttoptr i64 %0 to ptr
  %11 = getelementptr i8, ptr %10, i64 40
  %12 = bitcast ptr %11 to ptr
  %13 = load i64, ptr %12, align 4
  %14 = inttoptr i64 %0 to ptr
  %15 = getelementptr i8, ptr %14, i64 32
  %16 = bitcast ptr %15 to ptr
  %17 = load i64, ptr %16, align 4
  %18 = add i64 %13, 40
  %19 = icmp ult i64 %17, %18
  br i1 %19, label %B2, label %B3, !prof !2

B2:                                               ; preds = %B1
  %20 = call { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64 %0, i64 %9, i64 40) #12
  %21 = extractvalue { i64, ptr addrspace(1) } %20, 0
  %22 = extractvalue { i64, ptr addrspace(1) } %20, 1
  br label %B4

B3:                                               ; preds = %B1
  %23 = bitcast ptr %11 to ptr
  store i64 %18, ptr %23, align 4
  %24 = inttoptr i64 %13 to ptr
  %25 = getelementptr i8, ptr %24, i64 296
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
  %35 = inttoptr i64 %13 to ptr
  %36 = getelementptr i8, ptr %35, i64 16
  %37 = bitcast ptr %36 to ptr
  store i64 0, ptr %37, align 4
  %38 = inttoptr i64 %13 to ptr
  %39 = getelementptr i8, ptr %38, i64 24
  %40 = bitcast ptr %39 to ptr
  store i64 0, ptr %40, align 4
  %41 = inttoptr i64 %13 to ptr
  %42 = getelementptr i8, ptr %41, i64 32
  %43 = bitcast ptr %42 to ptr
  store i64 0, ptr %43, align 4
  %44 = call ptr addrspace(1) @__llvm_int_to_object(i64 %13)
  br label %B4

B4:                                               ; preds = %B3, %B2
  %45 = phi i64 [ %21, %B2 ], [ %0, %B3 ]
  %46 = phi ptr addrspace(1) [ %22, %B2 ], [ %44, %B3 ]
  fence seq_cst
  %47 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInterNoCatch_main_110bc46dad68ea45a6a3b5264a8cc092ec172d25#1", align 8
  %48 = call { i64 } @StringBuilder_constructor_15fe70429bc651383130f60cc6f49aafc708247c(i64 %45, ptr addrspace(1) %46) #13
  %49 = extractvalue { i64 } %48, 0
  br label %B5

B5:                                               ; preds = %B4
  %50 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInterNoCatch_main_110bc46dad68ea45a6a3b5264a8cc092ec172d25#2", align 8
  %51 = call { i64, ptr addrspace(1) } @StringBuilder_append_bb02350bf43a0b629fd161889a9183049f6dd0a8(i64 %49, ptr addrspace(1) %46, ptr addrspace(1) %50) #14
  %52 = extractvalue { i64, ptr addrspace(1) } %51, 0
  %53 = extractvalue { i64, ptr addrspace(1) } %51, 1
  br label %B6

B6:                                               ; preds = %B5
  %54 = call { i64, i32 } @NullPtrExceptionInterNoCatch_interNullPtrException_7110e26417e50866f3040c69099957d348a42bd8(i64 %52) #15
  %55 = extractvalue { i64, i32 } %54, 0
  %56 = extractvalue { i64, i32 } %54, 1
  br label %B7

B7:                                               ; preds = %B6
  %57 = icmp eq ptr addrspace(1) %53, null
  br i1 %57, label %B8, label %B9, !prof !4

B8:                                               ; preds = %B7
  %58 = call { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64 %55) #16
  %59 = extractvalue { i64 } %58, 0
  unreachable

B9:                                               ; preds = %B7
  %60 = call { i64, ptr addrspace(1) } @StringBuilder_append_4480f123c6e4bef4001c7d565e9c46895d0afb64(i64 %55, ptr addrspace(1) %53, i32 %56) #17
  %61 = extractvalue { i64, ptr addrspace(1) } %60, 0
  %62 = extractvalue { i64, ptr addrspace(1) } %60, 1
  br label %B10

B10:                                              ; preds = %B9
  %63 = icmp eq ptr addrspace(1) %62, null
  br i1 %63, label %B11, label %B12, !prof !4

B11:                                              ; preds = %B10
  %64 = call { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64 %61) #18
  %65 = extractvalue { i64 } %64, 0
  unreachable

B12:                                              ; preds = %B10
  %66 = call { i64, ptr addrspace(1) } @StringBuilder_toString_fff5cf8f9838ca54b87be4fc46d795a7c0e01bd4(i64 %61, ptr addrspace(1) %62) #19
  %67 = extractvalue { i64, ptr addrspace(1) } %66, 0
  %68 = extractvalue { i64, ptr addrspace(1) } %66, 1
  br label %B13

B13:                                              ; preds = %B12
  %69 = call { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64 %67, ptr addrspace(1) %47, ptr addrspace(1) %68) #20
  %70 = extractvalue { i64 } %69, 0
  br label %B14

B14:                                              ; preds = %B13
  %71 = inttoptr i64 %70 to ptr
  %72 = getelementptr i8, ptr %71, i32 16
  %73 = bitcast ptr %72 to ptr
  %74 = load i32, ptr %73, align 4
  %75 = sub i32 %74, 1
  %76 = bitcast ptr %72 to ptr
  store i32 %75, ptr %76, align 4
  %77 = icmp sle i32 %75, 0
  br i1 %77, label %B15, label %B16, !prof !5

B15:                                              ; preds = %B14
  %78 = call { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64 %70) #21
  %79 = extractvalue { i64 } %78, 0
  %80 = insertvalue { i64 } zeroinitializer, i64 %79, 0
  ret { i64 } %80

B16:                                              ; preds = %B14
  %81 = insertvalue { i64 } zeroinitializer, i64 %70, 0
  ret { i64 } %81

B17:                                              ; preds = %B0
  %82 = call { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64 %0) #22
  %83 = extractvalue { i64 } %82, 0
  unreachable
}

declare { i64 } @StringBuilder_constructor_15fe70429bc651383130f60cc6f49aafc708247c(i64, ptr addrspace(1))

declare { i64, ptr addrspace(1) } @StringBuilder_append_bb02350bf43a0b629fd161889a9183049f6dd0a8(i64, ptr addrspace(1), ptr addrspace(1))

declare { i64, ptr addrspace(1) } @StringBuilder_append_4480f123c6e4bef4001c7d565e9c46895d0afb64(i64, ptr addrspace(1), i32)

declare { i64, ptr addrspace(1) } @StringBuilder_toString_fff5cf8f9838ca54b87be4fc46d795a7c0e01bd4(i64, ptr addrspace(1))

declare { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64, ptr addrspace(1), ptr addrspace(1))



!0 = !{!"rsp\00"}
!1 = !{!"branch_weights", i32 2147481499, i32 2147}
!2 = !{!"branch_weights", i32 21474836, i32 2126008810}
!3 = !{!"branch_weights", i32 1073741823, i32 1073741823}
!4 = !{!"branch_weights", i32 2147, i32 2147481499}
!5 = !{!"branch_weights", i32 2147483, i32 2145336163}
