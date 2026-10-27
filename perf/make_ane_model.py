"""Build a conv-heavy Core ML mlprogram used to probe Neural Engine throughput."""
import os
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct

C, H, W, LAYERS = 64, 128, 128, 20

class ConvNet(nn.Module):
    def __init__(self):
        super().__init__()
        layers = []
        for _ in range(LAYERS):
            layers += [nn.Conv2d(C, C, 3, padding=1, bias=True), nn.ReLU()]
        self.net = nn.Sequential(*layers)

    def forward(self, x):
        return self.net(x)

model = ConvNet().eval()
example = torch.rand(1, C, H, W)
with torch.no_grad():
    traced = torch.jit.trace(model, example)
    traced = torch.jit.freeze(traced)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=example.shape)],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "models", "conv.mlpackage")
os.makedirs(os.path.dirname(out), exist_ok=True)
mlmodel.save(out)
print("saved", out)
