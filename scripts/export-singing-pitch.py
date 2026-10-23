#!/usr/bin/env python3
"""Build-time conversion of the MIT-licensed CREPE tiny singing/music F0 model.

Architecture adapted from torchcrepe 0.0.24 (MIT, copyright 2020 Max Morrison).
Weights originated in CREPE (Jong Wook Kim et al., ICASSP 2018, MIT).
The app runs only Core ML and never starts Python or downloads a model.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

WEIGHTS_SHA256 = "d4993eea36ed1a0ad9ac549c740dae5265b049ce72004f00c2f59e01c0be8432"


class CREPE(torch.nn.Module):
    def __init__(self):
        super().__init__()
        channels = [1, 128, 16, 16, 16, 32, 64]
        for i in range(1, 7):
            setattr(self, f"conv{i}", torch.nn.Conv2d(channels[i-1], channels[i],
                    (512 if i == 1 else 64, 1), stride=(4 if i == 1 else 1, 1)))
            setattr(self, f"conv{i}_BN", torch.nn.BatchNorm2d(channels[i],
                    eps=0.0010000000474974513, momentum=0.0))
        self.classifier = torch.nn.Linear(256, 360)

    def forward(self, audio):
        x = audio[:, None, :, None]
        for i in range(1, 7):
            x = F.pad(x, (0, 0, 254, 254) if i == 1 else (0, 0, 31, 32))
            x = getattr(self, f"conv{i}_BN")(F.relu(getattr(self, f"conv{i}")(x)))
            x = F.max_pool2d(x, (2, 1), (2, 1))
        x = x.permute(0, 2, 1, 3).reshape(-1, 256)
        return torch.sigmoid(self.classifier(x))


def load_model(weights):
    if hashlib.sha256(weights.read_bytes()).hexdigest() != WEIGHTS_SHA256:
        raise ValueError("CREPE tiny checkpoint checksum mismatch")
    model = CREPE().eval()
    model.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True))
    return model


def main():
    import coremltools as ct
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("build/singing-pitch"))
    args = parser.parse_args()
    torch.set_num_threads(1)
    model = load_model(args.directory / "crepe-tiny.pth")
    example = torch.zeros(1, 1024)
    traced = torch.jit.trace(model, example)
    converted = ct.convert(traced, inputs=[ct.TensorType(name="audio", shape=example.shape, dtype=np.float32)],
                           outputs=[ct.TensorType(name="activation", dtype=np.float32)],
                           convert_to="neuralnetwork", minimum_deployment_target=ct.target.macOS11,
                           compute_units=ct.ComputeUnit.CPU_ONLY)
    converted.author = "CREPE authors / Max Morrison; Core ML conversion for Miucs"
    converted.license = "MIT"
    converted.short_description = "CREPE tiny: 1024 mono PCM samples at 16 kHz to 360 pitch activations."
    converted.save(str(args.directory / "SingingPitch.mlmodel"))
    rng = np.random.default_rng(20261024)
    inputs = [np.zeros(1024, np.float32), rng.normal(0, .03, 1024).astype(np.float32)]
    inputs += [(a * np.sin(2 * np.pi * hz * np.arange(1024) / 16000)).astype(np.float32)
               for hz in [82.4, 196, 440, 880] for a in [.1, .001]]
    errors = []
    for signal in inputs:
        signal = signal - signal.mean()
        signal = (signal / max(float(signal.std(ddof=1)), 1e-10)).reshape(1, 1024)
        with torch.no_grad():
            expected = model(torch.from_numpy(signal)).numpy()
        actual = converted.predict({"audio": signal})["activation"]
        errors.append(float(np.max(np.abs(actual - expected))))
    if not all(np.isfinite(errors)) or max(errors) > .001:
        raise RuntimeError(f"Core ML numerical validation failed: {errors}")
    compiled = args.directory / "SingingPitch.mlmodelc"
    if compiled.exists():
        shutil.rmtree(compiled)
    shutil.copytree(converted.get_compiled_model_path(), compiled)
    report = {"model": "CREPE tiny", "weightsSHA256": WEIGHTS_SHA256,
              "exporterSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "torchcrepeVersion": "0.0.24", "torchcrepeRevision": "19e2ec3d494c0797a5ff2a11408ec5838fba6681",
              "torchVersion": torch.__version__, "coremltoolsVersion": ct.__version__,
              "maxActivationDifference": max(errors), "validationCases": len(errors)}
    (args.directory / "conversion.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
