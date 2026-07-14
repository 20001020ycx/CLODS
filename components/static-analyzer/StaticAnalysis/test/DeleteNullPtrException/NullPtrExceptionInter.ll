; ModuleID = 'NullPtrExceptionInter.bc'
source_filename = "llvm-link"

@"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#0" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#1" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#2" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#3" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#4" = external addrspace(1) global ptr addrspace(1)

; Function Attrs: noinline noredzone
define { i64, i32 } @NullPtrExceptionInter_interNullPtrException_09eaa9eabd701f4ea4a91e8454fb563238ec9839(i64 %0, i32 %1) #0 gc "compressed-pointer" personality ptr @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4 {
B0:
  call void (i64, i32, ...) @llvm.experimental.stackmap(i64 30296, i32 0)
  %2 = inttoptr i64 %0 to ptr
  %3 = getelementptr i8, ptr %2, i64 8
  %4 = bitcast ptr %3 to ptr
  %5 = load i64, ptr %4, align 4
  %6 = call i64 @llvm.read_register.i64(metadata !0)
  %7 = icmp ult i64 %5, %6
  br i1 %7, label %B1, label %B2, !prof !1

B1:                                               ; preds = %B0
  %8 = add i32 %1, -4321234
  %9 = call { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64 %0) #6
  %10 = extractvalue { i64 } %9, 0
  unreachable

B2:                                               ; preds = %B0
  %11 = call { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64 %0) #7
  %12 = extractvalue { i64 } %11, 0
  unreachable
}

declare { i64, i32 } @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4(i32, i32, i64, i64, i64)

; Function Attrs: nocallback nofree nosync willreturn
declare void @llvm.experimental.stackmap(i64, i32, ...) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(read)
declare i64 @llvm.read_register.i64(metadata) #2

declare { i64 } @ImplicitExceptions_throwNewNullPointerException_4005c48f410ebeb06be6e6d0cbe0438520f574fa(i64)

declare { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64)

; Function Attrs: noinline noredzone
define { i64 } @NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697(i64 %0, ptr addrspace(1) %1) #0 gc "compressed-pointer" personality ptr @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4 {
B0:
  call void (i64, i32, ...) @llvm.experimental.stackmap(i64 30196, i32 0)
  %2 = inttoptr i64 %0 to ptr
  %3 = getelementptr i8, ptr %2, i64 8
  %4 = bitcast ptr %3 to ptr
  %5 = load i64, ptr %4, align 4
  %6 = call i64 @llvm.read_register.i64(metadata !0)
  %7 = icmp ult i64 %5, %6
  br i1 %7, label %B1, label %B48, !prof !2

B1:                                               ; preds = %B0
  %8 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#0", align 8
  %9 = ptrtoint ptr addrspace(1) %8 to i64
  %10 = inttoptr i64 %0 to ptr
  %11 = getelementptr i8, ptr %10, i64 40
  %12 = bitcast ptr %11 to ptr
  %13 = load i64, ptr %12, align 4
  %14 = inttoptr i64 %0 to ptr
  %15 = getelementptr i8, ptr %14, i64 32
  %16 = bitcast ptr %15 to ptr
  %17 = load i64, ptr %16, align 4
  %18 = add i64 %13, 232
  %19 = icmp ult i64 %17, %18
  br i1 %19, label %B2, label %B3, !prof !3

B2:                                               ; preds = %B1
  %20 = call { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64 %0, i64 %9, i64 232) #8
  %21 = extractvalue { i64, ptr addrspace(1) } %20, 0
  %22 = extractvalue { i64, ptr addrspace(1) } %20, 1
  br label %B7

B3:                                               ; preds = %B1
  %23 = bitcast ptr %11 to ptr
  store i64 %18, ptr %23, align 4
  %24 = inttoptr i64 %13 to ptr
  %25 = getelementptr i8, ptr %24, i64 488
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
  %37 = icmp ult i64 %36, 232
  br i1 %37, label %B5, label %B6, !prof !4

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
  %45 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#1", align 8
  %46 = call { i64 } @Scanner_constructor_3f86ab6c173e6c247c9ae271c3c2586c89665361(i64 %43, ptr addrspace(1) %44, ptr addrspace(1) %45) #9
  %47 = extractvalue { i64 } %46, 0
  br label %B8

B8:                                               ; preds = %B7
  %48 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#2", align 8
  %49 = inttoptr i64 %0 to ptr
  %50 = getelementptr i8, ptr %49, i64 64
  %51 = inttoptr i64 %0 to ptr
  %52 = getelementptr i8, ptr %51, i64 20
  %53 = inttoptr i64 %0 to ptr
  %54 = getelementptr i8, ptr %53, i64 192
  %55 = invoke { i64, i32 } @Scanner_nextInt_433958df939a388be7924d6d2e0bb60afedb8549(i64 %47, ptr addrspace(1) %44) #10
          to label %B8_invoke_successor unwind label %B8_invoke_handler

B9:                                               ; preds = %B8_invoke_successor
  %56 = icmp eq i32 %184, 0
  br i1 %56, label %B10, label %B11, !prof !1

B10:                                              ; preds = %B9
  %57 = call { i64, ptr addrspace(1) } @ImplicitExceptions_createDivisionByZeroException_bde2faeda763faf148d374aca281e23cf22b1f42(i64 %183) #11
  %58 = extractvalue { i64, ptr addrspace(1) } %57, 0
  %59 = extractvalue { i64, ptr addrspace(1) } %57, 1
  br label %B46

B11:                                              ; preds = %B9
  %60 = sdiv i32 12138, %184
  %61 = add i32 %60, 1020324
  %62 = invoke { i64, i32 } @NullPtrExceptionInter_interNullPtrException_09eaa9eabd701f4ea4a91e8454fb563238ec9839(i64 %183, i32 %61) #12
          to label %B11_invoke_successor unwind label %B11_invoke_handler

B12:                                              ; preds = %B11_invoke_successor
  %63 = call { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64 %186, ptr addrspace(1) %44) #13
  %64 = extractvalue { i64 } %63, 0
  br label %B13

B13:                                              ; preds = %B12
  %65 = inttoptr i64 %64 to ptr
  %66 = getelementptr i8, ptr %65, i32 16
  %67 = bitcast ptr %66 to ptr
  %68 = load i32, ptr %67, align 4
  %69 = sub i32 %68, 1
  %70 = bitcast ptr %66 to ptr
  store i32 %69, ptr %70, align 4
  %71 = icmp sle i32 %69, 0
  br i1 %71, label %B14, label %B15, !prof !5

B14:                                              ; preds = %B13
  %72 = call { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64 %64) #14
  %73 = extractvalue { i64 } %72, 0
  %74 = insertvalue { i64 } zeroinitializer, i64 %73, 0
  ret { i64 } %74

B15:                                              ; preds = %B13
  %75 = insertvalue { i64 } zeroinitializer, i64 %64, 0
  ret { i64 } %75

B16:                                              ; preds = %B11_invoke_handler
  %76 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %183) #15
  %77 = extractvalue { i64, ptr addrspace(1) } %76, 0
  %78 = extractvalue { i64, ptr addrspace(1) } %76, 1
  fence seq_cst
  %79 = bitcast ptr %54 to ptr
  %80 = load i32, ptr %79, align 4
  fence seq_cst
  %81 = icmp eq i32 %80, 0
  br i1 %81, label %B17, label %B20, !prof !6

B17:                                              ; preds = %B16
  %82 = bitcast ptr %52 to ptr
  %83 = cmpxchg ptr %82, i32 3, i32 1 monotonic monotonic, align 4
  %84 = extractvalue { i32, i1 } %83, 1
  %85 = select i1 %84, i32 1, i32 0
  %86 = icmp eq i32 %85, 0
  br i1 %86, label %B18, label %B19, !prof !5

B18:                                              ; preds = %B17
  br label %B21

B19:                                              ; preds = %B17
  br label %B22

B20:                                              ; preds = %B16
  br label %B21

B21:                                              ; preds = %B20, %B18
  %87 = phi i64 [ %77, %B20 ], [ %77, %B18 ]
  %88 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %87, i32 1) #16
  %89 = extractvalue { i64 } %88, 0
  br label %B22

B22:                                              ; preds = %B21, %B19
  %90 = phi i64 [ %77, %B19 ], [ %89, %B21 ]
  %91 = bitcast ptr %50 to ptr
  %92 = load i64, ptr %91, align 4
  %93 = inttoptr i64 %92 to ptr
  %94 = getelementptr i8, ptr %93, i64 16
  %95 = bitcast ptr %94 to ptr
  %96 = load i64, ptr %95, align 4
  %97 = bitcast ptr %50 to ptr
  store i64 %96, ptr %97, align 4
  %98 = getelementptr i8, ptr addrspace(1) %78, i64 0
  %99 = bitcast ptr addrspace(1) %98 to ptr addrspace(1)
  %100 = load i64, ptr addrspace(1) %99, align 4
  %101 = and i64 %100, -8
  %102 = call ptr addrspace(1) @__llvm_int_to_object(i64 %101)
  %103 = icmp eq ptr addrspace(1) %102, %48
  br i1 %103, label %B23, label %B24, !prof !4

B23:                                              ; preds = %B22
  br label %B33

B24:                                              ; preds = %B22
  br label %B46

B25:                                              ; preds = %B8_invoke_handler
  %104 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %47) #17
  %105 = extractvalue { i64, ptr addrspace(1) } %104, 0
  %106 = extractvalue { i64, ptr addrspace(1) } %104, 1
  fence seq_cst
  %107 = bitcast ptr %54 to ptr
  %108 = load i32, ptr %107, align 4
  fence seq_cst
  %109 = icmp eq i32 %108, 0
  br i1 %109, label %B26, label %B29, !prof !6

B26:                                              ; preds = %B25
  %110 = bitcast ptr %52 to ptr
  %111 = cmpxchg ptr %110, i32 3, i32 1 monotonic monotonic, align 4
  %112 = extractvalue { i32, i1 } %111, 1
  %113 = select i1 %112, i32 1, i32 0
  %114 = icmp eq i32 %113, 0
  br i1 %114, label %B27, label %B28, !prof !5

B27:                                              ; preds = %B26
  br label %B30

B28:                                              ; preds = %B26
  br label %B31

B29:                                              ; preds = %B25
  br label %B30

B30:                                              ; preds = %B29, %B27
  %115 = phi i64 [ %105, %B29 ], [ %105, %B27 ]
  %116 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %115, i32 1) #18
  %117 = extractvalue { i64 } %116, 0
  br label %B31

B31:                                              ; preds = %B30, %B28
  %118 = phi i64 [ %105, %B28 ], [ %117, %B30 ]
  %119 = bitcast ptr %50 to ptr
  %120 = load i64, ptr %119, align 4
  %121 = inttoptr i64 %120 to ptr
  %122 = getelementptr i8, ptr %121, i64 16
  %123 = bitcast ptr %122 to ptr
  %124 = load i64, ptr %123, align 4
  %125 = bitcast ptr %50 to ptr
  store i64 %124, ptr %125, align 4
  %126 = getelementptr i8, ptr addrspace(1) %106, i64 0
  %127 = bitcast ptr addrspace(1) %126 to ptr addrspace(1)
  %128 = load i64, ptr addrspace(1) %127, align 4
  %129 = and i64 %128, -8
  %130 = call ptr addrspace(1) @__llvm_int_to_object(i64 %129)
  %131 = icmp eq ptr addrspace(1) %130, %48
  br i1 %131, label %B32, label %B45, !prof !4

B32:                                              ; preds = %B31
  br label %B33

B33:                                              ; preds = %B32, %B23
  %132 = phi i64 [ %118, %B32 ], [ %90, %B23 ]
  %133 = phi ptr addrspace(1) [ %106, %B32 ], [ %78, %B23 ]
  %134 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#3", align 8
  %135 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrExceptionInter_main_5a3ddce9eef5b3a7d154466cc2a82cbaf2e8b697#4", align 8
  %136 = invoke { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64 %132, ptr addrspace(1) %134, ptr addrspace(1) %135) #19
          to label %B33_invoke_successor unwind label %B33_invoke_handler

B34:                                              ; preds = %B33_invoke_successor
  %137 = call { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64 %189, ptr addrspace(1) %44) #20
  %138 = extractvalue { i64 } %137, 0
  br label %B35

B35:                                              ; preds = %B34
  %139 = inttoptr i64 %138 to ptr
  %140 = getelementptr i8, ptr %139, i32 16
  %141 = bitcast ptr %140 to ptr
  %142 = load i32, ptr %141, align 4
  %143 = sub i32 %142, 1
  %144 = bitcast ptr %140 to ptr
  store i32 %143, ptr %144, align 4
  %145 = icmp sle i32 %143, 0
  br i1 %145, label %B36, label %B37, !prof !5

B36:                                              ; preds = %B35
  %146 = call { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64 %138) #21
  %147 = extractvalue { i64 } %146, 0
  %148 = insertvalue { i64 } zeroinitializer, i64 %147, 0
  ret { i64 } %148

B37:                                              ; preds = %B35
  %149 = insertvalue { i64 } zeroinitializer, i64 %138, 0
  ret { i64 } %149

B38:                                              ; preds = %B33_invoke_handler
  %150 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %132) #22
  %151 = extractvalue { i64, ptr addrspace(1) } %150, 0
  %152 = extractvalue { i64, ptr addrspace(1) } %150, 1
  fence seq_cst
  %153 = bitcast ptr %54 to ptr
  %154 = load i32, ptr %153, align 4
  fence seq_cst
  %155 = icmp eq i32 %154, 0
  br i1 %155, label %B39, label %B42, !prof !6

B39:                                              ; preds = %B38
  %156 = bitcast ptr %52 to ptr
  %157 = cmpxchg ptr %156, i32 3, i32 1 monotonic monotonic, align 4
  %158 = extractvalue { i32, i1 } %157, 1
  %159 = select i1 %158, i32 1, i32 0
  %160 = icmp eq i32 %159, 0
  br i1 %160, label %B40, label %B41, !prof !5

B40:                                              ; preds = %B39
  br label %B43

B41:                                              ; preds = %B39
  br label %B44

B42:                                              ; preds = %B38
  br label %B43

B43:                                              ; preds = %B42, %B40
  %161 = phi i64 [ %151, %B42 ], [ %151, %B40 ]
  %162 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %161, i32 1) #23
  %163 = extractvalue { i64 } %162, 0
  br label %B44

B44:                                              ; preds = %B43, %B41
  %164 = phi i64 [ %151, %B41 ], [ %163, %B43 ]
  %165 = bitcast ptr %50 to ptr
  %166 = load i64, ptr %165, align 4
  %167 = inttoptr i64 %166 to ptr
  %168 = getelementptr i8, ptr %167, i64 16
  %169 = bitcast ptr %168 to ptr
  %170 = load i64, ptr %169, align 4
  %171 = bitcast ptr %50 to ptr
  store i64 %170, ptr %171, align 4
  br label %B46

B45:                                              ; preds = %B31
  br label %B46

B46:                                              ; preds = %B45, %B44, %B24, %B10
  %172 = phi i64 [ %118, %B45 ], [ %58, %B10 ], [ %90, %B24 ], [ %164, %B44 ]
  %173 = phi ptr addrspace(1) [ %106, %B45 ], [ %59, %B10 ], [ %78, %B24 ], [ %152, %B44 ]
  %174 = call { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64 %172, ptr addrspace(1) %44) #24
  %175 = extractvalue { i64 } %174, 0
  br label %B47

B47:                                              ; preds = %B46
  %176 = call ptr @llvm.frameaddress.p0(i32 0)
  %177 = ptrtoint ptr %176 to i64
  %178 = add i64 %177, 16
  %179 = call { i64 } @ExceptionUnwind_unwindExceptionWithoutCalleeSavedRegisters_a72be9b3a6eed0ebbe367f78f1788cfbc52c6377(i64 %175, ptr addrspace(1) %173, i64 %178) #25
  %180 = extractvalue { i64 } %179, 0
  unreachable

B48:                                              ; preds = %B0
  %181 = call { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64 %0) #26
  %182 = extractvalue { i64 } %181, 0
  unreachable

B8_invoke_successor:                              ; preds = %B8
  %183 = extractvalue { i64, i32 } %55, 0
  %184 = extractvalue { i64, i32 } %55, 1
  br label %B9

B8_invoke_handler:                                ; preds = %B8
  %185 = landingpad token
          catch ptr null
  br label %B25

B11_invoke_successor:                             ; preds = %B11
  %186 = extractvalue { i64, i32 } %62, 0
  %187 = extractvalue { i64, i32 } %62, 1
  br label %B12

B11_invoke_handler:                               ; preds = %B11
  %188 = landingpad token
          catch ptr null
  br label %B16

B33_invoke_successor:                             ; preds = %B33
  %189 = extractvalue { i64 } %136, 0
  br label %B34

B33_invoke_handler:                               ; preds = %B33
  %190 = landingpad token
          catch ptr null
  br label %B38
}

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

declare { i64, i32 } @Scanner_nextInt_433958df939a388be7924d6d2e0bb60afedb8549(i64, ptr addrspace(1))

declare { i64, ptr addrspace(1) } @ImplicitExceptions_createDivisionByZeroException_bde2faeda763faf148d374aca281e23cf22b1f42(i64)

declare { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64, ptr addrspace(1))

declare { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64)

declare { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64)

declare { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64, i32)

declare { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64, ptr addrspace(1), ptr addrspace(1))

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(none)
declare ptr @llvm.frameaddress.p0(i32 immarg) #5

declare { i64 } @ExceptionUnwind_unwindExceptionWithoutCalleeSavedRegisters_a72be9b3a6eed0ebbe367f78f1788cfbc52c6377(i64, ptr addrspace(1), i64)



!0 = !{!"rsp\00"}
!1 = !{!"branch_weights", i32 2147, i32 2147481499}
!2 = !{!"branch_weights", i32 2147481499, i32 2147}
!3 = !{!"branch_weights", i32 21474836, i32 2126008810}
!4 = !{!"branch_weights", i32 1073741823, i32 1073741823}
!5 = !{!"branch_weights", i32 2147483, i32 2145336163}
!6 = !{!"branch_weights", i32 2145336163, i32 2147483}
