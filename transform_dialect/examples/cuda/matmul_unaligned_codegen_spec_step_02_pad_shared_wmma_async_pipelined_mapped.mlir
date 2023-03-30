// Instructions; TL;DR
// ===================
//
// Note: this is currently dependent on merging the branch:
//   https://github.com/nicolasvasilache/iree/tree/matmul-unaligned
//
// ```
//   export IREE_DIR=${HOME}/github/iree; \
//   export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; \
//   cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir |\
//   sed "s/\${M}/1023/g" | sed "s/\${K}/2047/g" | sed "s/\${N}/4095/g" | \
//   sed "s/private @matmul_static(/@matmul_static(/g" | \
//   ${LLVM_BUILD_DIR}/bin/mlir-opt -symbol-dce |
//   ${IREE_DIR}/build/tools/iree-opt \
//     --iree-hal-target-backends=cuda \
//     --iree-abi-transformation-pipeline \
//     --iree-flow-transformation-pipeline \
//     --iree-stream-transformation-pipeline \
//     --iree-hal-configuration-pipeline | \
//   ${IREE_DIR}/build/tools/iree-opt \
//      --pass-pipeline='builtin.module(hal.executable(hal.executable.variant(iree-llvmgpu-lower-executable-target)))' \
//      --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_unaligned_codegen_spec_step_02_pad_shared_wmma_async_pipelined_mapped.mlir \
//      --iree-codegen-llvmgpu-enable-transform-dialect-jit=false
// ```
//
// To produce PTX:
// ```
//   export IREE_DIR=${HOME}/github/iree; 
//   export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; 
//   cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir | \
//   sed "s/\${M}/1023/g" | sed "s/\${K}/2047/g" | sed "s/\${N}/4095/g" | \
//   sed "s/private @matmul_static(/@matmul_static(/g" | \
//   ${LLVM_BUILD_DIR}/bin/mlir-opt -symbol-dce |
//   ${IREE_DIR}/build/tools/iree-compile - \
//     --iree-hal-target-backends=cuda --iree-hal-cuda-llvm-target-arch=sm_80 \
//     --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_unaligned_codegen_spec_step_02_pad_shared_wmma_async_pipelined_mapped.mlir \
//     --iree-codegen-llvmgpu-enable-transform-dialect-jit=false 
// ```
//
// To run e2e on a remote machine (${A100_MACHINE_IP}) with an A100 GPU:
// ```
//   # Do this only once:
//   # scp ${IREE_DIR}/build/tools/iree-run-module ${USER}@${A100_MACHINE_IP}:~/;
//
//   export IREE_DIR=${HOME}/github/iree; 
//   export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; 
//   cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir | \
//   sed "s/\${M}/1023/g" | sed "s/\${K}/2047/g" | sed "s/\${N}/4095/g" | \
//   sed "s/private @matmul_static(/@matmul_static(/g" | \
//   ${LLVM_BUILD_DIR}/bin/mlir-opt -symbol-dce |
//   ${IREE_DIR}/build/tools/iree-compile - \
//     --iree-hal-target-backends=cuda --iree-hal-cuda-llvm-target-arch=sm_80 \
//     --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_unaligned_codegen_spec_step_02_pad_shared_wmma_async_pipelined_mapped.mlir \
//     --iree-codegen-llvmgpu-enable-transform-dialect-jit=false \
//     --iree-hal-benchmark-dispatch-repeat-count=5 \
//     -o /tmp/foo.vmfb; \
//   scp /tmp/foo.vmfb ${USER}@${A100_MACHINE_IP}:~/ > /dev/null; \
//   ssh ${USER}@${A100_MACHINE_IP} "/usr/local/cuda/bin/nsys profile --stats=true ~/iree-run-module --function=matmul_static --device=cuda --module=foo.vmfb --input=1023x2047xf32=1 --input=2047x4095xf32=1 --input=1023x4095xf32=1 2>&1" | \
//   grep matmul_static_dispatch | awk '{print $6}'
//
//   # The above prints the min across the 5 invocations.
//   # Alternatively, grep a little more to see what happens in more detail.
//   grep -3 matmul_static_dispatch
// ```
//
// The above command simply prints `370944` (i.e. 0.371 million nanoseconds).
//
//
// Alternatively, run with the profiler:
// ```
//   export IREE_DIR=${HOME}/github/iree; 
//   export IREE_SAMPLES_DIR=${HOME}/github/iree-samples; 
//   cat ${IREE_SAMPLES_DIR}/transform_dialect/examples/matmul.mlir | \
//   sed "s/\${M}/1023/g" | sed "s/\${K}/2047/g" | sed "s/\${N}/4095/g" | \
//   sed "s/private @matmul_static(/@matmul_static(/g" | \
//   ${LLVM_BUILD_DIR}/bin/mlir-opt -symbol-dce |
//   ${IREE_DIR}/build/tools/iree-compile - \
//     --iree-hal-target-backends=cuda --iree-hal-cuda-llvm-target-arch=sm_80 \
//     --iree-codegen-llvmgpu-use-transform-dialect=${IREE_SAMPLES_DIR}/transform_dialect/examples/cuda/matmul_unaligned_codegen_spec_step_02_pad_shared_wmma_async_pipelined_mapped.mlir \
//     --iree-codegen-llvmgpu-enable-transform-dialect-jit=false \
//     -o /tmp/foo.vmfb; \
//   scp /tmp/foo.vmfb ${USER}@${A100_MACHINE_IP}:~/ > /dev/null; \
//   ssh ${USER}@${A100_MACHINE_IP} "sudo /usr/local/cuda/bin/ncu -f --set full -o profile ~/iree-run-module --function=matmul_static --device=cuda --module=foo.vmfb \
//     --input=1023x2047xf32=1 --input=2047x4095xf32=1 --input=1023x4095xf32=1"
// ```
//
transform.sequence failures(propagate) {
^bb1(%variant_op: !pdl.operation):
  // %fill = transform.structured.match ops{["linalg.fill"]} in %variant_op
  //   : (!pdl.operation) -> !pdl.operation
  %matmul = transform.structured.match ops{["linalg.matmul"]} in %variant_op
    : (!pdl.operation) -> !pdl.operation

  // Step 1. Tile to forall and sequential scf.for.
  // ======================================================
  %forall_l1, %matmul_l1 =
    transform.iree.tile_to_forall_and_workgroup_count_region %matmul tile_sizes [128, 128]
      ( mapping = [#gpu.block<y>, #gpu.block<x>] )
  // %fill_l1 = transform.structured.fuse_into_containing_op %fill into %forall_l1
  %matmul_l2, %loops:1 = transform.structured.tile_to_scf_for %matmul_l1 [0, 0, 16]
  // Post-tiling canonicalizations and cleanups.
  transform.iree.apply_patterns %variant_op 
    {canonicalization, cse, licm, tiling_canonicalization} : (!pdl.operation) -> ()

  // Step 2. Pad the matmul and force packing to create the buffer in shared memory
  // Note: hoisting here may be dangerous memory-consumption-wise and we may be
  // better off with pipelining only.
  // ==============================================================================
  %matmul_padded_l2 = transform.structured.pad %matmul_l2 {
    padding_values = [0.0 : f32, 0.0 : f32, 0.0 : f32], 
    padding_dimensions = [0, 1, 2], 
    pack_paddings=[1, 1, 1]
  }
  // %fill_padded_l1 = transform.structured.pad %fill_l1 {
  //   padding_values = [0.0 : f32, 0.0 : f32], 
  //   padding_dimensions = [0, 1, 2], 
  //   pack_paddings=[0, 1]
  // }
  // Post-padding canonicalizations and cleanups.
  transform.iree.apply_patterns %variant_op 
    {canonicalization, cse, licm, tiling_canonicalization} : (!pdl.operation) -> ()

  // Step 3. Rewrite tensor.pad in DPS, this creates linalg.copy ops.
  // ================================================================
  %pad = transform.structured.match ops{["tensor.pad"]} in %variant_op 
    : (!pdl.operation) -> !pdl.operation
  %padded = transform.structured.rewrite_in_destination_passing_style %pad 
    : (!pdl.operation) -> !pdl.operation
  transform.iree.apply_patterns %variant_op 
    {canonicalization} : (!pdl.operation) -> ()

  // Step 4. Map to threads, **SIMT** programming model.
  // // ===================================================
  // %insert_lhs = transform.get_producer_of_operand %matmul_padded_l2[0] 
  //    : (!pdl.operation) -> !pdl.operation
  // %copy_lhs = transform.get_producer_of_operand %insert_lhs[0] 
  //    : (!pdl.operation) -> !pdl.operation
  // %extract_lhs = transform.get_producer_of_operand %copy_lhs[1] 
  //    : (!pdl.operation) -> !pdl.operation
  // %fill_lhs = transform.get_producer_of_operand %extract_lhs[0] 
  //    : (!pdl.operation) -> !pdl.operation
  // transform.structured.tile_to_forall_op %fill_lhs num_threads [32, 4]
  //     ( mapping = [#gpu.linear<y>, #gpu.linear<x>] )
  // transform.structured.tile_to_forall_op %copy_lhs num_threads [32, 4]
  //     ( mapping = [#gpu.linear<y>, #gpu.linear<x>] )


  // %insert_rhs = transform.get_producer_of_operand %matmul_padded_l2[1] 
  //    : (!pdl.operation) -> !pdl.operation
  // %copy_rhs = transform.get_producer_of_operand %insert_rhs[0] 
  //    : (!pdl.operation) -> !pdl.operation
  // %extract_rhs = transform.get_producer_of_operand %copy_rhs[1] 
  //    : (!pdl.operation) -> !pdl.operation
  // %fill_rhs = transform.get_producer_of_operand %extract_rhs[0] 
  //    : (!pdl.operation) -> !pdl.operation
  // transform.structured.tile_to_forall_op %fill_rhs num_threads [4, 32]
  //     ( mapping = [#gpu.linear<y>, #gpu.linear<x>] )
  // transform.structured.tile_to_forall_op %copy_rhs num_threads [4, 32]
  //     ( mapping = [#gpu.linear<y>, #gpu.linear<x>] )

  transform.iree.apply_patterns %variant_op 
    {canonicalization, cse, licm} : (!pdl.operation) -> ()

  // Step 5. Contraction part mapped to threads with a **SIMD** programming model.
  // =============================================================================
  %forall_l3, %matmul_padded_l3 = 
    transform.structured.tile_to_forall_op %matmul_padded_l2 num_threads [2, 2]
      ( mapping = [#gpu.warp<y>, #gpu.warp<x>] )
  // %forall_fill_l3, %fill_l3 = 
  //   transform.structured.tile_to_forall_op %fill_padded_l1 num_threads [2, 2]
  //     ( mapping = [#gpu.warp<y>, #gpu.warp<x>] )

  // Step 6. Rank-reduce and vectorize.
  // ==================================
  %func_v = transform.structured.match ops{["func.func"]} in %variant_op
    : (!pdl.operation) -> !pdl.operation
  transform.iree.apply_patterns %func_v { rank_reducing_linalg, rank_reducing_vector }
    : (!pdl.operation) -> ()
  %func_v_3 = transform.structured.vectorize %func_v { vectorize_padding }
  // Post-vectorization canonicalizations and hoistings to avoid roundtripping 
  // vectors in memory and prepare for bufferization.
  transform.iree.apply_patterns %func_v_3 {canonicalization, cse, licm }
    : (!pdl.operation) -> ()
  %func_v_5 = transform.structured.hoist_redundant_tensor_subsets %func_v_3
    : (!pdl.operation) -> !pdl.operation

  // Step 7. Bufferize and drop HAL descriptor from memref ops.
  // ==========================================================
  // Pre-buferization canonicalizations and cleanups help avoid extra copies.
  transform.iree.apply_patterns %func_v_5 {canonicalization, cse, licm}
    : (!pdl.operation) -> ()
  transform.iree.eliminate_empty_tensors %variant_op : (!pdl.operation) -> ()
  %variant_op_3 = transform.iree.bufferize { target_gpu } %variant_op
    : (!pdl.operation) -> (!pdl.operation)
  %func_m = transform.structured.match ops{["func.func"]} in %variant_op_3 
    : (!pdl.operation) -> !pdl.operation
  transform.iree.erase_hal_descriptor_type_from_memref %func_m
    : (!pdl.operation) -> ()
  transform.iree.apply_buffer_optimizations %func_m : (!pdl.operation) -> ()

  // // Step 8. Post-bufferization mapping blocks/workgroup and threads/subgroup.
  // // =========================================================================
  // transform.iree.apply_patterns %variant_op_3 
  //   {canonicalization, cse, licm, tiling_canonicalization}
  //   : (!pdl.operation) -> ()
  // transform.iree.forall_to_workgroup %func_m : (!pdl.operation) -> ()
  // transform.iree.map_nested_forall_to_gpu_threads %func_m
  //     workgroup_dims = [64, 2, 1] warp_dims = [2, 2, 1]
  //   : (!pdl.operation) -> ()

  // //===---------------------------------------------------------------------===//
  // // BEGIN - Annoying phase-ordered section
  // //===---------------------------------------------------------------------===//
  // // Vector transfer_read and transfer_write patterns have different subview
  // // folding behavior, force a fold_memref_aliases on them to enable redundant
  // // vector transfer hoisting.
  // // Unfortunately, fold_memref_aliases breaks vector_to_mma conversion across 
  // // scf.for after unrolling dur to insert_strided_slice / extract_strided_slice
  // // across iter_args boundaries.
  // // transform.iree.apply_patterns %func_m {canonicalize, cse, fold_memref_aliases}
  // //   : (!pdl.operation) -> ()
  // transform.iree.apply_patterns %func_m {canonicalize, cse, licm}
  //   : (!pdl.operation) -> ()
  // transform.iree.apply_patterns %func_m { unroll_vectors_gpu_wmma }
  //   : (!pdl.operation) -> ()

  // // Blanket canonicalizations and folding interact weirdly with buferization
  // // and create linalg.copy ops that we want to vectorize.
  // // Things still connect but somewhat by luck.
  // %func_m_2 = transform.structured.vectorize %func_m { vectorize_padding }

  // // Hoist redundant vector transfers to allow vectorization to proceed.
  // // We really don't want to do this after bufferization but we need to atm.
  // // One way to work around this is to hoist the pad ops on the output earlier 
  // // but this has other tradeoffs. Still needs some investigation.
  // %func_m_8 = transform.structured.hoist_redundant_vector_transfers %func_m_2
  //   : (!pdl.operation) -> !pdl.operation

  // transform.iree.apply_patterns %func_m_8 
  //   {canonicalization, cse, licm, tiling_canonicalization}
  //   : (!pdl.operation) -> ()
  // // TODO: this currently fails to apply mem2reg due to asymmetrical 
  // // subview/subtensor folding. We are still missing an LLVM integrate before 
  // // this can occur. 
  // transform.iree.apply_buffer_optimizations %func_m_8 : (!pdl.operation) -> ()

  // // This must occur after bufferization because of the fancy CUDA types.
  // transform.iree.vector.vector_to_mma_conversion %func_m_8 { use_wmma }
  //   : (!pdl.operation) -> ()
  // //===---------------------------------------------------------------------===//
  // // END - Annoying phase-ordered section
  // //===---------------------------------------------------------------------===//

  // // Step 9. Multi-buffering.
  // // =========================================================================
  // transform.iree.apply_patterns %func_m_8 {canonicalize, cse}
  //   : (!pdl.operation) -> ()
  // // Hoist static allocs to allow multi-buffering to proceed.
  // transform.iree.hoist_static_alloc %func_m_8 : (!pdl.operation) -> ()
  // %allocs = transform.structured.match ops{["memref.alloc"]} in %func_m_8
  //   : (!pdl.operation) -> !transform.op<"memref.alloc">
  // %mb_allocs = transform.memref.multibuffer %allocs {factor = 5 : i64, skip_analysis } 
  //   : (!transform.op<"memref.alloc">) -> !pdl.operation

  // // Step 10. Cp-async.
  // // ===========================================================================
  // // Lower remaining vector ops to 1-D which will trigger the cp-async.
  // // Alternatively we could explicitly unroll to 1-D innermost vectors if we 
  // // wanted a specific target shape.
  // %func_m_9 = transform.vector.transfer_to_scf %func_m_8
  //   max_transfer_rank = 1 full_unroll = true
  //     : (!pdl.operation) -> !pdl.operation
  // transform.iree.create_async_groups %func_m_9 {use_mma_sync = false} 
  //   : (!pdl.operation) -> ()
  // transform.iree.apply_patterns %func_m_9 {canonicalize, cse, fold_memref_aliases, licm}
  //   : (!pdl.operation) -> ()

  // // // Step 11. Pipeline shared memory copies.
  // // // ===========================================================================
  // // %mma_compute = transform.structured.match ops{["gpu.subgroup_mma_compute"]} in %variant_op_3
  // //   : (!pdl.operation) -> !pdl.operation
  // // // Pre pipelining cleanups.
  // // transform.iree.apply_patterns %func_m_9 {canonicalization, cse}
  // //   : (!pdl.operation) -> ()
  // // %for = transform.loop.get_parent_for %mma_compute : (!pdl.operation) -> !transform.op<"scf.for">
  // // %pipelined_for = transform.iree.pipeline_shared_memory_copies %for { depth = 5 } 
  // //   : (!transform.op<"scf.for">) -> !transform.op<"scf.for">

  // // Late canonicalizations and cleanups.
  // transform.iree.apply_patterns %variant_op_3 
  //   {canonicalization, cse, licm, tiling_canonicalization}
  //   : (!pdl.operation) -> ()


}
