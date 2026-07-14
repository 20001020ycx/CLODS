; ModuleID = 'f1.bc'
source_filename = "NullPtrException.main"

@"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#0" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#1" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#2" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#3" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#4" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#5" = external addrspace(1) global ptr addrspace(1)
@"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#6" = external addrspace(1) global ptr addrspace(1)

; Function Attrs: noinline noredzone
define { i64 } @NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1(i64 %0, ptr addrspace(1) %1) #0 gc "compressed-pointer" personality ptr @IsolateEnterStub_LLVMExceptionUnwind_personality_6715a663d94f995518d057e92a9c4ae4293ffca2_f13871289d9839292ba0106f623976b447e2efd4 {
B0:
  call void (i64, i32, ...) @llvm.experimental.stackmap(i64 25342, i32 0)
  %2 = inttoptr i64 %0 to ptr
  %3 = getelementptr i8, ptr %2, i64 8
  %4 = bitcast ptr %3 to ptr
  %5 = load i64, ptr %4, align 4
  %6 = call i64 @llvm.read_register.i64(metadata !0)
  %7 = icmp ult i64 %5, %6
  br i1 %7, label %B1, label %B108, !prof !1

B1:                                               ; preds = %B0
  %8 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#0", align 8
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
  %20 = call { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64 %0, i64 %9, i64 224) #6
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
  %45 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#1", align 8
  %46 = call { i64 } @Scanner_constructor_3f86ab6c173e6c247c9ae271c3c2586c89665361(i64 %43, ptr addrspace(1) %44, ptr addrspace(1) %45) #7
  %47 = extractvalue { i64 } %46, 0
  br label %B8

B8:                                               ; preds = %B7
  %48 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#2", align 8
  %49 = inttoptr i64 %0 to ptr
  %50 = getelementptr i8, ptr %49, i64 64
  %51 = inttoptr i64 %0 to ptr
  %52 = getelementptr i8, ptr %51, i64 20
  %53 = inttoptr i64 %0 to ptr
  %54 = getelementptr i8, ptr %53, i64 192
  %55 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#3", align 8
  %56 = invoke { i64, ptr addrspace(1) } @Scanner_nextLine_de0f6fd26bac70c51c277bba341e6d8607054963(i64 %47, ptr addrspace(1) %44) #8
          to label %B8_invoke_successor unwind label %B8_invoke_handler

B9:                                               ; preds = %B8_invoke_successor
  %57 = icmp eq ptr addrspace(1) %378, null
  br i1 %57, label %B10, label %B11, !prof !4

B10:                                              ; preds = %B9
  %58 = call { i64, ptr addrspace(1) } @ImplicitExceptions_createNullPointerException_73d3fd94610b144dbff38af3343b54950172c1fb(i64 %377) #9
  %59 = extractvalue { i64, ptr addrspace(1) } %58, 0
  %60 = extractvalue { i64, ptr addrspace(1) } %58, 1
  br label %B82

B11:                                              ; preds = %B9
  %61 = invoke { i64, i32 } @String_length_c8bec93b04b501e5e0144a1d586f117cb490caca(i64 %377, ptr addrspace(1) %378) #10
          to label %B11_invoke_successor unwind label %B11_invoke_handler

B12:                                              ; preds = %B11_invoke_successor
  %62 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#4", align 8
  %63 = ptrtoint ptr addrspace(1) %62 to i64
  %64 = bitcast ptr %11 to ptr
  %65 = load i64, ptr %64, align 4
  %66 = bitcast ptr %15 to ptr
  %67 = load i64, ptr %66, align 4
  %68 = add i64 %65, 40
  %69 = icmp ult i64 %67, %68
  br i1 %69, label %B13, label %B14, !prof !2

B13:                                              ; preds = %B12
  %70 = call { i64, ptr addrspace(1) } @ThreadLocalAllocation_slowPathNewInstance_39ae850940ab632d109995344de15fd9d3b31d84(i64 %380, i64 %63, i64 40) #11
  %71 = extractvalue { i64, ptr addrspace(1) } %70, 0
  %72 = extractvalue { i64, ptr addrspace(1) } %70, 1
  br label %B15

B14:                                              ; preds = %B12
  %73 = bitcast ptr %11 to ptr
  store i64 %68, ptr %73, align 4
  %74 = inttoptr i64 %65 to ptr
  %75 = getelementptr i8, ptr %74, i64 296
  call void @llvm.prefetch.p0(ptr %75, i32 1, i32 0, i32 1)
  %76 = inttoptr i64 %65 to ptr
  %77 = getelementptr i8, ptr %76, i64 0
  %78 = bitcast ptr %77 to ptr
  store i64 %63, ptr %78, align 4
  %79 = inttoptr i64 %65 to ptr
  %80 = getelementptr i8, ptr %79, i64 8
  %81 = bitcast ptr %80 to ptr
  store i32 0, ptr %81, align 4
  %82 = inttoptr i64 %65 to ptr
  %83 = getelementptr i8, ptr %82, i64 12
  %84 = bitcast ptr %83 to ptr
  store i32 0, ptr %84, align 4
  %85 = inttoptr i64 %65 to ptr
  %86 = getelementptr i8, ptr %85, i64 16
  %87 = bitcast ptr %86 to ptr
  store i64 0, ptr %87, align 4
  %88 = inttoptr i64 %65 to ptr
  %89 = getelementptr i8, ptr %88, i64 24
  %90 = bitcast ptr %89 to ptr
  store i64 0, ptr %90, align 4
  %91 = inttoptr i64 %65 to ptr
  %92 = getelementptr i8, ptr %91, i64 32
  %93 = bitcast ptr %92 to ptr
  store i64 0, ptr %93, align 4
  %94 = call ptr addrspace(1) @__llvm_int_to_object(i64 %65)
  br label %B15

B15:                                              ; preds = %B14, %B13
  %95 = phi i64 [ %71, %B13 ], [ %380, %B14 ]
  %96 = phi ptr addrspace(1) [ %72, %B13 ], [ %94, %B14 ]
  fence seq_cst
  %97 = add i32 %381, 123456
  %98 = invoke { i64 } @StringBuilder_constructor_15fe70429bc651383130f60cc6f49aafc708247c(i64 %95, ptr addrspace(1) %96) #12
          to label %B15_invoke_successor unwind label %B15_invoke_handler

B16:                                              ; preds = %B15_invoke_successor
  %99 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#5", align 8
  %100 = invoke { i64, ptr addrspace(1) } @StringBuilder_append_bb02350bf43a0b629fd161889a9183049f6dd0a8(i64 %383, ptr addrspace(1) %96, ptr addrspace(1) %99) #13
          to label %B16_invoke_successor unwind label %B16_invoke_handler

B17:                                              ; preds = %B16_invoke_successor
  %101 = icmp eq ptr addrspace(1) %386, null
  br i1 %101, label %B18, label %B19, !prof !4

B18:                                              ; preds = %B17
  %102 = call { i64, ptr addrspace(1) } @ImplicitExceptions_createNullPointerException_73d3fd94610b144dbff38af3343b54950172c1fb(i64 %385) #14
  %103 = extractvalue { i64, ptr addrspace(1) } %102, 0
  %104 = extractvalue { i64, ptr addrspace(1) } %102, 1
  br label %B54

B19:                                              ; preds = %B17
  %105 = invoke { i64, ptr addrspace(1) } @StringBuilder_append_4480f123c6e4bef4001c7d565e9c46895d0afb64(i64 %385, ptr addrspace(1) %386, i32 %97) #15
          to label %B19_invoke_successor unwind label %B19_invoke_handler

B20:                                              ; preds = %B19_invoke_successor
  %106 = icmp eq ptr addrspace(1) %389, null
  br i1 %106, label %B21, label %B22, !prof !4

B21:                                              ; preds = %B20
  %107 = call { i64, ptr addrspace(1) } @ImplicitExceptions_createNullPointerException_73d3fd94610b144dbff38af3343b54950172c1fb(i64 %388) #16
  %108 = extractvalue { i64, ptr addrspace(1) } %107, 0
  %109 = extractvalue { i64, ptr addrspace(1) } %107, 1
  br label %B44

B22:                                              ; preds = %B20
  %110 = invoke { i64, ptr addrspace(1) } @StringBuilder_toString_fff5cf8f9838ca54b87be4fc46d795a7c0e01bd4(i64 %388, ptr addrspace(1) %389) #17
          to label %B22_invoke_successor unwind label %B22_invoke_handler

B23:                                              ; preds = %B22_invoke_successor
  %111 = invoke { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64 %391, ptr addrspace(1) %55, ptr addrspace(1) %392) #18
          to label %B23_invoke_successor unwind label %B23_invoke_handler

B24:                                              ; preds = %B23_invoke_successor
  %112 = call { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64 %394, ptr addrspace(1) %44) #19
  %113 = extractvalue { i64 } %112, 0
  br label %B25

B25:                                              ; preds = %B24
  %114 = inttoptr i64 %113 to ptr
  %115 = getelementptr i8, ptr %114, i32 16
  %116 = bitcast ptr %115 to ptr
  %117 = load i32, ptr %116, align 4
  %118 = sub i32 %117, 1
  %119 = bitcast ptr %115 to ptr
  store i32 %118, ptr %119, align 4
  %120 = icmp sle i32 %118, 0
  br i1 %120, label %B26, label %B27, !prof !5

B26:                                              ; preds = %B25
  %121 = call { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64 %113) #20
  %122 = extractvalue { i64 } %121, 0
  %123 = insertvalue { i64 } zeroinitializer, i64 %122, 0
  ret { i64 } %123

B27:                                              ; preds = %B25
  %124 = insertvalue { i64 } zeroinitializer, i64 %113, 0
  ret { i64 } %124

B28:                                              ; preds = %B23_invoke_handler
  %125 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %391) #21
  %126 = extractvalue { i64, ptr addrspace(1) } %125, 0
  %127 = extractvalue { i64, ptr addrspace(1) } %125, 1
  fence seq_cst
  %128 = bitcast ptr %54 to ptr
  %129 = load i32, ptr %128, align 4
  fence seq_cst
  %130 = icmp eq i32 %129, 0
  br i1 %130, label %B29, label %B32, !prof !6

B29:                                              ; preds = %B28
  %131 = bitcast ptr %52 to ptr
  %132 = cmpxchg ptr %131, i32 3, i32 1 monotonic monotonic, align 4
  %133 = extractvalue { i32, i1 } %132, 1
  %134 = select i1 %133, i32 1, i32 0
  %135 = icmp eq i32 %134, 0
  br i1 %135, label %B30, label %B31, !prof !5

B30:                                              ; preds = %B29
  br label %B33

B31:                                              ; preds = %B29
  br label %B34

B32:                                              ; preds = %B28
  br label %B33

B33:                                              ; preds = %B32, %B30
  %136 = phi i64 [ %126, %B32 ], [ %126, %B30 ]
  %137 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %136, i32 1) #22
  %138 = extractvalue { i64 } %137, 0
  br label %B34

B34:                                              ; preds = %B33, %B31
  %139 = phi i64 [ %126, %B31 ], [ %138, %B33 ]
  %140 = bitcast ptr %50 to ptr
  %141 = load i64, ptr %140, align 4
  %142 = inttoptr i64 %141 to ptr
  %143 = getelementptr i8, ptr %142, i64 16
  %144 = bitcast ptr %143 to ptr
  %145 = load i64, ptr %144, align 4
  %146 = bitcast ptr %50 to ptr
  store i64 %145, ptr %146, align 4
  %147 = getelementptr i8, ptr addrspace(1) %127, i64 0
  %148 = bitcast ptr addrspace(1) %147 to ptr addrspace(1)
  %149 = load i64, ptr addrspace(1) %148, align 4
  %150 = and i64 %149, -8
  %151 = call ptr addrspace(1) @__llvm_int_to_object(i64 %150)
  %152 = icmp eq ptr addrspace(1) %151, %48
  br i1 %152, label %B35, label %B36, !prof !3

B35:                                              ; preds = %B34
  br label %B93

B36:                                              ; preds = %B34
  br label %B106

B37:                                              ; preds = %B22_invoke_handler
  %153 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %388) #23
  %154 = extractvalue { i64, ptr addrspace(1) } %153, 0
  %155 = extractvalue { i64, ptr addrspace(1) } %153, 1
  fence seq_cst
  %156 = bitcast ptr %54 to ptr
  %157 = load i32, ptr %156, align 4
  fence seq_cst
  %158 = icmp eq i32 %157, 0
  br i1 %158, label %B38, label %B41, !prof !6

B38:                                              ; preds = %B37
  %159 = bitcast ptr %52 to ptr
  %160 = cmpxchg ptr %159, i32 3, i32 1 monotonic monotonic, align 4
  %161 = extractvalue { i32, i1 } %160, 1
  %162 = select i1 %161, i32 1, i32 0
  %163 = icmp eq i32 %162, 0
  br i1 %163, label %B39, label %B40, !prof !5

B39:                                              ; preds = %B38
  br label %B42

B40:                                              ; preds = %B38
  br label %B43

B41:                                              ; preds = %B37
  br label %B42

B42:                                              ; preds = %B41, %B39
  %164 = phi i64 [ %154, %B41 ], [ %154, %B39 ]
  %165 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %164, i32 1) #24
  %166 = extractvalue { i64 } %165, 0
  br label %B43

B43:                                              ; preds = %B42, %B40
  %167 = phi i64 [ %154, %B40 ], [ %166, %B42 ]
  %168 = bitcast ptr %50 to ptr
  %169 = load i64, ptr %168, align 4
  %170 = inttoptr i64 %169 to ptr
  %171 = getelementptr i8, ptr %170, i64 16
  %172 = bitcast ptr %171 to ptr
  %173 = load i64, ptr %172, align 4
  %174 = bitcast ptr %50 to ptr
  store i64 %173, ptr %174, align 4
  br label %B44

B44:                                              ; preds = %B43, %B21
  %175 = phi i64 [ %108, %B21 ], [ %167, %B43 ]
  %176 = phi ptr addrspace(1) [ %109, %B21 ], [ %155, %B43 ]
  %177 = getelementptr i8, ptr addrspace(1) %176, i64 0
  %178 = bitcast ptr addrspace(1) %177 to ptr addrspace(1)
  %179 = load i64, ptr addrspace(1) %178, align 4
  %180 = and i64 %179, -8
  %181 = call ptr addrspace(1) @__llvm_int_to_object(i64 %180)
  %182 = icmp eq ptr addrspace(1) %181, %48
  br i1 %182, label %B45, label %B46, !prof !3

B45:                                              ; preds = %B44
  br label %B93

B46:                                              ; preds = %B44
  br label %B106

B47:                                              ; preds = %B19_invoke_handler
  %183 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %385) #25
  %184 = extractvalue { i64, ptr addrspace(1) } %183, 0
  %185 = extractvalue { i64, ptr addrspace(1) } %183, 1
  fence seq_cst
  %186 = bitcast ptr %54 to ptr
  %187 = load i32, ptr %186, align 4
  fence seq_cst
  %188 = icmp eq i32 %187, 0
  br i1 %188, label %B48, label %B51, !prof !6

B48:                                              ; preds = %B47
  %189 = bitcast ptr %52 to ptr
  %190 = cmpxchg ptr %189, i32 3, i32 1 monotonic monotonic, align 4
  %191 = extractvalue { i32, i1 } %190, 1
  %192 = select i1 %191, i32 1, i32 0
  %193 = icmp eq i32 %192, 0
  br i1 %193, label %B49, label %B50, !prof !5

B49:                                              ; preds = %B48
  br label %B52

B50:                                              ; preds = %B48
  br label %B53

B51:                                              ; preds = %B47
  br label %B52

B52:                                              ; preds = %B51, %B49
  %194 = phi i64 [ %184, %B51 ], [ %184, %B49 ]
  %195 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %194, i32 1) #26
  %196 = extractvalue { i64 } %195, 0
  br label %B53

B53:                                              ; preds = %B52, %B50
  %197 = phi i64 [ %184, %B50 ], [ %196, %B52 ]
  %198 = bitcast ptr %50 to ptr
  %199 = load i64, ptr %198, align 4
  %200 = inttoptr i64 %199 to ptr
  %201 = getelementptr i8, ptr %200, i64 16
  %202 = bitcast ptr %201 to ptr
  %203 = load i64, ptr %202, align 4
  %204 = bitcast ptr %50 to ptr
  store i64 %203, ptr %204, align 4
  br label %B54

B54:                                              ; preds = %B53, %B18
  %205 = phi i64 [ %103, %B18 ], [ %197, %B53 ]
  %206 = phi ptr addrspace(1) [ %104, %B18 ], [ %185, %B53 ]
  %207 = getelementptr i8, ptr addrspace(1) %206, i64 0
  %208 = bitcast ptr addrspace(1) %207 to ptr addrspace(1)
  %209 = load i64, ptr addrspace(1) %208, align 4
  %210 = and i64 %209, -8
  %211 = call ptr addrspace(1) @__llvm_int_to_object(i64 %210)
  %212 = icmp eq ptr addrspace(1) %211, %48
  br i1 %212, label %B55, label %B56, !prof !3

B55:                                              ; preds = %B54
  br label %B93

B56:                                              ; preds = %B54
  br label %B106

B57:                                              ; preds = %B16_invoke_handler
  %213 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %383) #27
  %214 = extractvalue { i64, ptr addrspace(1) } %213, 0
  %215 = extractvalue { i64, ptr addrspace(1) } %213, 1
  fence seq_cst
  %216 = bitcast ptr %54 to ptr
  %217 = load i32, ptr %216, align 4
  fence seq_cst
  %218 = icmp eq i32 %217, 0
  br i1 %218, label %B58, label %B61, !prof !6

B58:                                              ; preds = %B57
  %219 = bitcast ptr %52 to ptr
  %220 = cmpxchg ptr %219, i32 3, i32 1 monotonic monotonic, align 4
  %221 = extractvalue { i32, i1 } %220, 1
  %222 = select i1 %221, i32 1, i32 0
  %223 = icmp eq i32 %222, 0
  br i1 %223, label %B59, label %B60, !prof !5

B59:                                              ; preds = %B58
  br label %B62

B60:                                              ; preds = %B58
  br label %B63

B61:                                              ; preds = %B57
  br label %B62

B62:                                              ; preds = %B61, %B59
  %224 = phi i64 [ %214, %B61 ], [ %214, %B59 ]
  %225 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %224, i32 1) #28
  %226 = extractvalue { i64 } %225, 0
  br label %B63

B63:                                              ; preds = %B62, %B60
  %227 = phi i64 [ %214, %B60 ], [ %226, %B62 ]
  %228 = bitcast ptr %50 to ptr
  %229 = load i64, ptr %228, align 4
  %230 = inttoptr i64 %229 to ptr
  %231 = getelementptr i8, ptr %230, i64 16
  %232 = bitcast ptr %231 to ptr
  %233 = load i64, ptr %232, align 4
  %234 = bitcast ptr %50 to ptr
  store i64 %233, ptr %234, align 4
  %235 = getelementptr i8, ptr addrspace(1) %215, i64 0
  %236 = bitcast ptr addrspace(1) %235 to ptr addrspace(1)
  %237 = load i64, ptr addrspace(1) %236, align 4
  %238 = and i64 %237, -8
  %239 = call ptr addrspace(1) @__llvm_int_to_object(i64 %238)
  %240 = icmp eq ptr addrspace(1) %239, %48
  br i1 %240, label %B64, label %B65, !prof !3

B64:                                              ; preds = %B63
  br label %B93

B65:                                              ; preds = %B63
  br label %B106

B66:                                              ; preds = %B15_invoke_handler
  %241 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %95) #29
  %242 = extractvalue { i64, ptr addrspace(1) } %241, 0
  %243 = extractvalue { i64, ptr addrspace(1) } %241, 1
  fence seq_cst
  %244 = bitcast ptr %54 to ptr
  %245 = load i32, ptr %244, align 4
  fence seq_cst
  %246 = icmp eq i32 %245, 0
  br i1 %246, label %B67, label %B70, !prof !6

B67:                                              ; preds = %B66
  %247 = bitcast ptr %52 to ptr
  %248 = cmpxchg ptr %247, i32 3, i32 1 monotonic monotonic, align 4
  %249 = extractvalue { i32, i1 } %248, 1
  %250 = select i1 %249, i32 1, i32 0
  %251 = icmp eq i32 %250, 0
  br i1 %251, label %B68, label %B69, !prof !5

B68:                                              ; preds = %B67
  br label %B71

B69:                                              ; preds = %B67
  br label %B72

B70:                                              ; preds = %B66
  br label %B71

B71:                                              ; preds = %B70, %B68
  %252 = phi i64 [ %242, %B70 ], [ %242, %B68 ]
  %253 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %252, i32 1) #30
  %254 = extractvalue { i64 } %253, 0
  br label %B72

B72:                                              ; preds = %B71, %B69
  %255 = phi i64 [ %242, %B69 ], [ %254, %B71 ]
  %256 = bitcast ptr %50 to ptr
  %257 = load i64, ptr %256, align 4
  %258 = inttoptr i64 %257 to ptr
  %259 = getelementptr i8, ptr %258, i64 16
  %260 = bitcast ptr %259 to ptr
  %261 = load i64, ptr %260, align 4
  %262 = bitcast ptr %50 to ptr
  store i64 %261, ptr %262, align 4
  %263 = getelementptr i8, ptr addrspace(1) %243, i64 0
  %264 = bitcast ptr addrspace(1) %263 to ptr addrspace(1)
  %265 = load i64, ptr addrspace(1) %264, align 4
  %266 = and i64 %265, -8
  %267 = call ptr addrspace(1) @__llvm_int_to_object(i64 %266)
  %268 = icmp eq ptr addrspace(1) %267, %48
  br i1 %268, label %B73, label %B74, !prof !3

B73:                                              ; preds = %B72
  br label %B93

B74:                                              ; preds = %B72
  br label %B106

B75:                                              ; preds = %B11_invoke_handler
  %269 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %377) #31
  %270 = extractvalue { i64, ptr addrspace(1) } %269, 0
  %271 = extractvalue { i64, ptr addrspace(1) } %269, 1
  fence seq_cst
  %272 = bitcast ptr %54 to ptr
  %273 = load i32, ptr %272, align 4
  fence seq_cst
  %274 = icmp eq i32 %273, 0
  br i1 %274, label %B76, label %B79, !prof !6

B76:                                              ; preds = %B75
  %275 = bitcast ptr %52 to ptr
  %276 = cmpxchg ptr %275, i32 3, i32 1 monotonic monotonic, align 4
  %277 = extractvalue { i32, i1 } %276, 1
  %278 = select i1 %277, i32 1, i32 0
  %279 = icmp eq i32 %278, 0
  br i1 %279, label %B77, label %B78, !prof !5

B77:                                              ; preds = %B76
  br label %B80

B78:                                              ; preds = %B76
  br label %B81

B79:                                              ; preds = %B75
  br label %B80

B80:                                              ; preds = %B79, %B77
  %280 = phi i64 [ %270, %B79 ], [ %270, %B77 ]
  %281 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %280, i32 1) #32
  %282 = extractvalue { i64 } %281, 0
  br label %B81

B81:                                              ; preds = %B80, %B78
  %283 = phi i64 [ %270, %B78 ], [ %282, %B80 ]
  %284 = bitcast ptr %50 to ptr
  %285 = load i64, ptr %284, align 4
  %286 = inttoptr i64 %285 to ptr
  %287 = getelementptr i8, ptr %286, i64 16
  %288 = bitcast ptr %287 to ptr
  %289 = load i64, ptr %288, align 4
  %290 = bitcast ptr %50 to ptr
  store i64 %289, ptr %290, align 4
  br label %B82

B82:                                              ; preds = %B81, %B10
  %291 = phi i64 [ %59, %B10 ], [ %283, %B81 ]
  %292 = phi ptr addrspace(1) [ %60, %B10 ], [ %271, %B81 ]
  %293 = getelementptr i8, ptr addrspace(1) %292, i64 0
  %294 = bitcast ptr addrspace(1) %293 to ptr addrspace(1)
  %295 = load i64, ptr addrspace(1) %294, align 4
  %296 = and i64 %295, -8
  %297 = call ptr addrspace(1) @__llvm_int_to_object(i64 %296)
  %298 = icmp eq ptr addrspace(1) %297, %48
  br i1 %298, label %B83, label %B84, !prof !3

B83:                                              ; preds = %B82
  br label %B93

B84:                                              ; preds = %B82
  br label %B106

B85:                                              ; preds = %B8_invoke_handler
  %299 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %47) #33
  %300 = extractvalue { i64, ptr addrspace(1) } %299, 0
  %301 = extractvalue { i64, ptr addrspace(1) } %299, 1
  fence seq_cst
  %302 = bitcast ptr %54 to ptr
  %303 = load i32, ptr %302, align 4
  fence seq_cst
  %304 = icmp eq i32 %303, 0
  br i1 %304, label %B86, label %B89, !prof !6

B86:                                              ; preds = %B85
  %305 = bitcast ptr %52 to ptr
  %306 = cmpxchg ptr %305, i32 3, i32 1 monotonic monotonic, align 4
  %307 = extractvalue { i32, i1 } %306, 1
  %308 = select i1 %307, i32 1, i32 0
  %309 = icmp eq i32 %308, 0
  br i1 %309, label %B87, label %B88, !prof !5

B87:                                              ; preds = %B86
  br label %B90

B88:                                              ; preds = %B86
  br label %B91

B89:                                              ; preds = %B85
  br label %B90

B90:                                              ; preds = %B89, %B87
  %310 = phi i64 [ %300, %B89 ], [ %300, %B87 ]
  %311 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %310, i32 1) #34
  %312 = extractvalue { i64 } %311, 0
  br label %B91

B91:                                              ; preds = %B90, %B88
  %313 = phi i64 [ %300, %B88 ], [ %312, %B90 ]
  %314 = bitcast ptr %50 to ptr
  %315 = load i64, ptr %314, align 4
  %316 = inttoptr i64 %315 to ptr
  %317 = getelementptr i8, ptr %316, i64 16
  %318 = bitcast ptr %317 to ptr
  %319 = load i64, ptr %318, align 4
  %320 = bitcast ptr %50 to ptr
  store i64 %319, ptr %320, align 4
  %321 = getelementptr i8, ptr addrspace(1) %301, i64 0
  %322 = bitcast ptr addrspace(1) %321 to ptr addrspace(1)
  %323 = load i64, ptr addrspace(1) %322, align 4
  %324 = and i64 %323, -8
  %325 = call ptr addrspace(1) @__llvm_int_to_object(i64 %324)
  %326 = icmp eq ptr addrspace(1) %325, %48
  br i1 %326, label %B92, label %B105, !prof !3

B92:                                              ; preds = %B91
  br label %B93

B93:                                              ; preds = %B92, %B83, %B73, %B64, %B55, %B45, %B35
  %327 = phi i64 [ %313, %B92 ], [ %291, %B83 ], [ %255, %B73 ], [ %227, %B64 ], [ %205, %B55 ], [ %175, %B45 ], [ %139, %B35 ]
  %328 = phi ptr addrspace(1) [ %301, %B92 ], [ %292, %B83 ], [ %243, %B73 ], [ %215, %B64 ], [ %206, %B55 ], [ %176, %B45 ], [ %127, %B35 ]
  %329 = load ptr addrspace(1), ptr addrspace(1) @"constant_NullPtrException_main_7775fa5d5f989d711bc7c3835f11179124215bd1#6", align 8
  %330 = invoke { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64 %327, ptr addrspace(1) %55, ptr addrspace(1) %329) #35
          to label %B93_invoke_successor unwind label %B93_invoke_handler

B94:                                              ; preds = %B93_invoke_successor
  %331 = call { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64 %396, ptr addrspace(1) %44) #36
  %332 = extractvalue { i64 } %331, 0
  br label %B95

B95:                                              ; preds = %B94
  %333 = inttoptr i64 %332 to ptr
  %334 = getelementptr i8, ptr %333, i32 16
  %335 = bitcast ptr %334 to ptr
  %336 = load i32, ptr %335, align 4
  %337 = sub i32 %336, 1
  %338 = bitcast ptr %334 to ptr
  store i32 %337, ptr %338, align 4
  %339 = icmp sle i32 %337, 0
  br i1 %339, label %B96, label %B97, !prof !5

B96:                                              ; preds = %B95
  %340 = call { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64 %332) #37
  %341 = extractvalue { i64 } %340, 0
  %342 = insertvalue { i64 } zeroinitializer, i64 %341, 0
  ret { i64 } %342

B97:                                              ; preds = %B95
  %343 = insertvalue { i64 } zeroinitializer, i64 %332, 0
  ret { i64 } %343

B98:                                              ; preds = %B93_invoke_handler
  %344 = call { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64 %327) #38
  %345 = extractvalue { i64, ptr addrspace(1) } %344, 0
  %346 = extractvalue { i64, ptr addrspace(1) } %344, 1
  fence seq_cst
  %347 = bitcast ptr %54 to ptr
  %348 = load i32, ptr %347, align 4
  fence seq_cst
  %349 = icmp eq i32 %348, 0
  br i1 %349, label %B99, label %B102, !prof !6

B99:                                              ; preds = %B98
  %350 = bitcast ptr %52 to ptr
  %351 = cmpxchg ptr %350, i32 3, i32 1 monotonic monotonic, align 4
  %352 = extractvalue { i32, i1 } %351, 1
  %353 = select i1 %352, i32 1, i32 0
  %354 = icmp eq i32 %353, 0
  br i1 %354, label %B100, label %B101, !prof !5

B100:                                             ; preds = %B99
  br label %B103

B101:                                             ; preds = %B99
  br label %B104

B102:                                             ; preds = %B98
  br label %B103

B103:                                             ; preds = %B102, %B100
  %355 = phi i64 [ %345, %B102 ], [ %345, %B100 ]
  %356 = call { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64 %355, i32 1) #39
  %357 = extractvalue { i64 } %356, 0
  br label %B104

B104:                                             ; preds = %B103, %B101
  %358 = phi i64 [ %345, %B101 ], [ %357, %B103 ]
  %359 = bitcast ptr %50 to ptr
  %360 = load i64, ptr %359, align 4
  %361 = inttoptr i64 %360 to ptr
  %362 = getelementptr i8, ptr %361, i64 16
  %363 = bitcast ptr %362 to ptr
  %364 = load i64, ptr %363, align 4
  %365 = bitcast ptr %50 to ptr
  store i64 %364, ptr %365, align 4
  br label %B106

B105:                                             ; preds = %B91
  br label %B106

B106:                                             ; preds = %B105, %B104, %B84, %B74, %B65, %B56, %B46, %B36
  %366 = phi i64 [ %313, %B105 ], [ %291, %B84 ], [ %255, %B74 ], [ %227, %B65 ], [ %205, %B56 ], [ %175, %B46 ], [ %139, %B36 ], [ %358, %B104 ]
  %367 = phi ptr addrspace(1) [ %301, %B105 ], [ %292, %B84 ], [ %243, %B74 ], [ %215, %B65 ], [ %206, %B56 ], [ %176, %B46 ], [ %127, %B36 ], [ %346, %B104 ]
  %368 = call { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64 %366, ptr addrspace(1) %44) #40
  %369 = extractvalue { i64 } %368, 0
  br label %B107

B107:                                             ; preds = %B106
  %370 = call ptr @llvm.frameaddress.p0(i32 0)
  %371 = ptrtoint ptr %370 to i64
  %372 = add i64 %371, 16
  %373 = call { i64 } @ExceptionUnwind_unwindExceptionWithoutCalleeSavedRegisters_a72be9b3a6eed0ebbe367f78f1788cfbc52c6377(i64 %369, ptr addrspace(1) %367, i64 %372) #41
  %374 = extractvalue { i64 } %373, 0
  unreachable

B108:                                             ; preds = %B0
  %375 = call { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64 %0) #42
  %376 = extractvalue { i64 } %375, 0
  unreachable

B8_invoke_successor:                              ; preds = %B8
  %377 = extractvalue { i64, ptr addrspace(1) } %56, 0
  %378 = extractvalue { i64, ptr addrspace(1) } %56, 1
  br label %B9

B8_invoke_handler:                                ; preds = %B8
  %379 = landingpad token
          catch ptr null
  br label %B85

B11_invoke_successor:                             ; preds = %B11
  %380 = extractvalue { i64, i32 } %61, 0
  %381 = extractvalue { i64, i32 } %61, 1
  br label %B12

B11_invoke_handler:                               ; preds = %B11
  %382 = landingpad token
          catch ptr null
  br label %B75

B15_invoke_successor:                             ; preds = %B15
  %383 = extractvalue { i64 } %98, 0
  br label %B16

B15_invoke_handler:                               ; preds = %B15
  %384 = landingpad token
          catch ptr null
  br label %B66

B16_invoke_successor:                             ; preds = %B16
  %385 = extractvalue { i64, ptr addrspace(1) } %100, 0
  %386 = extractvalue { i64, ptr addrspace(1) } %100, 1
  br label %B17

B16_invoke_handler:                               ; preds = %B16
  %387 = landingpad token
          catch ptr null
  br label %B57

B19_invoke_successor:                             ; preds = %B19
  %388 = extractvalue { i64, ptr addrspace(1) } %105, 0
  %389 = extractvalue { i64, ptr addrspace(1) } %105, 1
  br label %B20

B19_invoke_handler:                               ; preds = %B19
  %390 = landingpad token
          catch ptr null
  br label %B47

B22_invoke_successor:                             ; preds = %B22
  %391 = extractvalue { i64, ptr addrspace(1) } %110, 0
  %392 = extractvalue { i64, ptr addrspace(1) } %110, 1
  br label %B23

B22_invoke_handler:                               ; preds = %B22
  %393 = landingpad token
          catch ptr null
  br label %B37

B23_invoke_successor:                             ; preds = %B23
  %394 = extractvalue { i64 } %111, 0
  br label %B24

B23_invoke_handler:                               ; preds = %B23
  %395 = landingpad token
          catch ptr null
  br label %B28

B93_invoke_successor:                             ; preds = %B93
  %396 = extractvalue { i64 } %330, 0
  br label %B94

B93_invoke_handler:                               ; preds = %B93
  %397 = landingpad token
          catch ptr null
  br label %B98
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

declare { i64, ptr addrspace(1) } @ImplicitExceptions_createNullPointerException_73d3fd94610b144dbff38af3343b54950172c1fb(i64)

declare { i64, i32 } @String_length_c8bec93b04b501e5e0144a1d586f117cb490caca(i64, ptr addrspace(1))

declare { i64 } @StringBuilder_constructor_15fe70429bc651383130f60cc6f49aafc708247c(i64, ptr addrspace(1))

declare { i64, ptr addrspace(1) } @StringBuilder_append_bb02350bf43a0b629fd161889a9183049f6dd0a8(i64, ptr addrspace(1), ptr addrspace(1))

declare { i64, ptr addrspace(1) } @StringBuilder_append_4480f123c6e4bef4001c7d565e9c46895d0afb64(i64, ptr addrspace(1), i32)

declare { i64, ptr addrspace(1) } @StringBuilder_toString_fff5cf8f9838ca54b87be4fc46d795a7c0e01bd4(i64, ptr addrspace(1))

declare { i64 } @PrintStream_println_f593729257942307f0e76e88b8ac75793942d994(i64, ptr addrspace(1), ptr addrspace(1))

declare { i64 } @Scanner_close_918618c3fd407655af10354520fb9aa684cdc1c1(i64, ptr addrspace(1))

declare { i64 } @Safepoint_enterSlowPathSafepointCheck_6065687f19bea4c522a5ace56dcc1231d113e373(i64)

declare { i64, ptr addrspace(1) } @LLVMExceptionUnwind_retrieveException_54f820eb1562a43bc8ac45ec532eaebf7953101e(i64)

declare { i64 } @Safepoint_enterSlowPathTransitionFromNativeToNewStatus_cf7fa5a608efdf2ee42d3a5d02e1abbe748fdb53(i64, i32)

declare { i64 } @ExceptionUnwind_unwindExceptionWithoutCalleeSavedRegisters_a72be9b3a6eed0ebbe367f78f1788cfbc52c6377(i64, ptr addrspace(1), i64)

declare { i64 } @StackOverflowCheckSnippets_throwNewStackOverflowError_d3212575561bd35f8d5679c68d3664f797596772(i64)

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @llvm.prefetch.p0(ptr nocapture readonly, i32 immarg, i32 immarg, i32 immarg) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(none)
declare ptr @llvm.frameaddress.p0(i32 immarg) #5

!0 = !{!"rsp\00"}
!1 = !{!"branch_weights", i32 2147481499, i32 2147}
!2 = !{!"branch_weights", i32 21474836, i32 2126008810}
!3 = !{!"branch_weights", i32 1073741823, i32 1073741823}
!4 = !{!"branch_weights", i32 2147, i32 2147481499}
!5 = !{!"branch_weights", i32 2147483, i32 2145336163}
!6 = !{!"branch_weights", i32 2145336163, i32 2147483}
