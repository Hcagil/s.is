#!/usr/bin/env python3

import numpy as np
import onnx
import onnx.utils
import subprocess
import os
import shutil
from ai_edge_litert.interpreter import Interpreter
import onnxruntime as ort

# Step 1: Trim the ONNX model to one output
onnx.utils.extract_model('u2netp.onnx', 'u2netp_d0.onnx', ['input'], ['d0'])

# Step 2: Create calibration sample file for onnx2tf
np.save('calibration_image_sample_data_20x128x128x3_float32.npy', np.random.RandomState(0).rand(20,128,128,3).astype(np.float32))

# Step 3: Convert ONNX to TensorFlow Lite
subprocess.run(['onnx2tf','-i','u2netp_d0.onnx','-o','out'], check=True)

# Step 4: Numeric check with test inputs

# Define test inputs
yy, xx = np.mgrid[0:320, 0:320]/319.0
d = ((yy-.5)**2 + (xx-.5)**2 < 0.1).astype(np.float32)
t1 = np.stack([d*1.5-.5, d*.8-.5, d*-.2-.4])[None].astype(np.float32)
t2 = np.random.RandomState(1).randn(1,3,320,320).astype(np.float32)*0.8
t3 = np.stack([xx*2-1, yy*2-1, (xx*yy)*2-1])[None].astype(np.float32)
tests = [t1, t2, t3]

# Reference using ONNX Runtime
ref_session = ort.InferenceSession('u2netp.onnx')

# Check float32 model
model_path = 'out/u2netp_d0_float32.tflite'
interpreter = Interpreter(model_path=model_path)
interpreter.allocate_tensors()
input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

exit_code = 0
for i, x in enumerate(tests):
    # Get reference output
    ref = ref_session.run(['d0'], {'input': x})[0]
    
    # Run TFLite model
    interpreter.set_tensor(input_details[0]['index'], x.transpose(0,2,3,1))
    interpreter.invoke()
    out = interpreter.get_tensor(output_details[0]['index'])
    
    # Compare outputs
    diff = np.abs(out.reshape(-1) - ref.reshape(-1)).max()
    print(f'maxabs_d0 {model_path} {i+1} {diff}')
    if diff > 1e-3:
        exit_code = 1

# Check float16 model
model_path = 'out/u2netp_d0_float16.tflite'
interpreter = Interpreter(model_path=model_path)
interpreter.allocate_tensors()
input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

for i, x in enumerate(tests):
    # Get reference output
    ref = ref_session.run(['d0'], {'input': x})[0]
    
    # Run TFLite model
    interpreter.set_tensor(input_details[0]['index'], x.transpose(0,2,3,1))
    interpreter.invoke()
    out = interpreter.get_tensor(output_details[0]['index'])
    
    # Compare outputs
    diff = np.abs(out.reshape(-1) - ref.reshape(-1)).max()
    print(f'maxabs_d0 {model_path} {i+1} {diff}')

# Step 5: Copy files to final names
shutil.copy('out/u2netp_d0_float32.tflite', 'u2netp.tflite')
shutil.copy('out/u2netp_d0_float16.tflite', 'u2netp_fp16.tflite')

exit(exit_code)
