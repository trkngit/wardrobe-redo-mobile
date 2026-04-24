# Research artifacts — Multi-Garment Detection (2026-04-18)

Long-form notes that back the decisions in the canonical plan. Kept as a separate file so the plan stays scannable while the research is still auditable.

---

## Model license audit (why we ruled out the "obvious" choices)

### Why not Mask R-CNN

The canonical instance segmentation architecture. MIT-licensed in torchvision. Broken for Core ML:

- `torchvision::roi_align` has no native Core ML op. This is the blocker.
- coremltools issue #2479 is still open. Apple hasn't shipped a fix.
- The two reference repos (`xta0/CoreML-MaskRCNN`, `edouardlp/Mask-RCNN-CoreML`) are 4-6 years old, pre-coremltools 8, and require splitting the model into 3 separate `.mlpackage` files with manual Metal + Accelerate glue to bridge the gap.
- Latency on iPhone 13 even with painful integration: 300-800 ms. RF-DETR-Seg is 4-10x faster and converts cleanly.

### Why not ModaNet

Perfect fashion dataset. Perfect Mask R-CNN fit. **CC BY-NC 4.0** — non-commercial only. Fatal for App Store. The annotations propagate the license to any model trained on them.

### Why not DeepFashion2

"Research only" in the license. Explicitly forbids redistribution of derivatives.

### Why not SegFormer-fashion

- `mattmdjaga/segformer_b2_clothes` — converts cleanly, 18 classes, perfect fit. Blocked by **NVIDIA SegFormer's non-commercial license**.
- `sayeed99/segformer-b3-fashion` — same NVIDIA license chain.

### Why not YOLOv8-seg / YOLOv11-seg

Excellent iOS conversion path (Ultralytics ships a reference iOS app). **AGPL-3.0** — distribution triggers source obligation on the entire app. Requires Ultralytics Enterprise license to ship commercially.

### Why not YOLO-NAS-seg (Deci)

Code is Apache 2.0. **Pretrained weights are "research only".** Training from scratch forfeits the benefit; we'd be using it as a random init.

### Why not SCHP (ATR variant)

MIT code but ATR dataset has no LICENSE file at all. Legal ambiguity = rule-out.

### RF-DETR-Seg-Small — the winner

- Apache 2.0 on Nano/Small/Medium/Large variants (XL and 2XL are under PML 1.0, skip those).
- DETR-style end-to-end transformer with DINOv2 backbone. **No anchors, no NMS, no RoIAlign.** Every op maps cleanly to Core ML MIL.
- Roboflow explicitly designs for ANE and ships an official Swift SDK.
- Reported (detection variant): 54.7% mAP on COCO at 4.52 ms per inference on a T4 GPU.
- Segmentation variant landed in RF-DETR 1.4 (late 2025).
- Nano/Small variants should land under 150 MB at FP16; 30-50 MB after 6-bit palettization.
- Apple has confirmed the DINOv2 backbone architecture maps to ANE via the Depth Anything V2 conversion.

### SAM 2 Tiny + classifier head — the backup

- Apache 2.0, Apple ships a pre-converted ANE-optimized build (`apple/coreml-sam2-tiny`, 38.9 MB FP16).
- Class-agnostic — only produces masks, not labels. Needs a classification head on top.
- ResNet-18 fine-tuned on Fashionpedia crops (~5 MB FP16) gives us labels. Total ~45 MB.
- Uses `VNDetectHumanBodyPose3DRequest` (iOS 17+, iPhone 12 Pro+) for auto-prompts when a person is in the photo (shoulder/hip joints as positive points). Falls back to grid-of-points for flat-lay garments.
- Integration risk is lower than RF-DETR-Seg because Apple has done the ANE conversion already. But detection quality is lower without a dedicated per-instance detection head.

---

## Fashionpedia dataset — why it's the right dataset

The only large-scale fashion instance segmentation dataset with a clean commercial license.

- **License (annotations):** CC BY 4.0. Commercial use OK with attribution.
- **License (images):** Most are Creative Commons; the CVDF host filters to CC-licensed only.
- **Size:** 46,781 images.
- **Apparel main classes:** 27 — jacket, shirt, top, sweater, cardigan, dress, skirt, pants, shorts, coat, vest, jumpsuit, cape, glasses, hat, headband, sock, shoe, bag, scarf, tights, leg warmer, glove, bracelet, ring, watch, belt, and more.
- **Garment parts:** 19.
- **Attributes:** 294 (long-sleeve / short-sleeve, cotton / denim / leather, etc.). Not needed for v1 but opens a path to auto-subcategory in v1.1.
- **Annotation format:** COCO-format instance polygons + bboxes — exactly what RF-DETR expects.
- **Hosted by:** CVDF (Common Visual Data Foundation), HuggingFace `detection-datasets/fashionpedia`.

Strict superset of the user's reported problem (jacket, top, skirt, sunglasses) and adds bonus classes (bag, hat, scarf) that Modanet wouldn't have provided.

---

## Class collapse to 6-case enum

The existing `ClothingCategory` has: `.top`, `.bottom`, `.shoe`, `.dress`, `.outerwear`, `.accessory`. Fashionpedia's 27 classes fold into these:

- `.top` ← `shirt_blouse`, `top_t-shirt_sweatshirt`, `sweater`, `vest`, `cardigan`
- `.bottom` ← `pants`, `shorts`, `tights_stockings`, `skirt`
- `.dress` ← `dress`, `jumpsuit`
- `.outerwear` ← `coat`, `jacket`, `cape`
- `.shoe` ← `shoe`, `boot`, `sandal`
- `.accessory` ← `glasses`, `sunglasses`, `hat`, `headband`, `scarf`, `tie`, `bag_wallet`, `belt`, `glove`, `watch`, `ring`, `bracelet`, `earring`, `necklace`
- `nil` (not surfaced in v1) ← `sock`, `leg_warmer`, `umbrella`

This compromise keeps v1 behind the existing Supabase CHECK constraint. v1.1 splits `.accessory` into `.bag`, `.eyewear`, `.hat`, `.jewelry` with a coordinated migration.

---

## Core ML conversion — gotchas we already know about

- **Go direct PyTorch → Core ML. Not via ONNX.** ONNX adds two format conversions, each with op-mapping drift. Direct conversion from `torch.jit.trace` is the Apple-recommended path in 2025.
- **Fixed input shape.** ANE residency requires static shapes. DETR naturally outputs a fixed number of query tokens (typically 100), so keep that.
- **Post-process in Swift.** Sigmoid / argmax / NMS on the Swift side, not inside the Core ML graph. The graph stays pure tensor ops; post-processing is logic.
- **Quantize to 6-bit palettized `per_grouped_channel`**, matching the existing SAM2 pattern. 4-bit is too aggressive for mask edges.
- **Verify ANE residency via Instruments.** Core ML template shows which ops land on ANE vs CPU/GPU. If anything falls back, investigate and rewrite (common fix: `Linear` → `Conv2d` 1×1).

---

## Background Assets framework (WWDC25)

Critical if the compressed model exceeds ~30-50 MB (which is likely unless we ship Nano).

- **Apple-hosted variant** released WWDC25 (session 325). Apple hosts the binary on their CDN. No infra to maintain.
- Mark the model as essential in `BackgroundAssets.json`. iOS downloads in the background between app install and first launch.
- If the download is still in flight at first launch, show a one-time "Preparing AI model" progress sheet. Otherwise fall back to single-item flow silently — user never sees a broken state.
- `.mlpackage` → `MLModel.compileModel(at:)` once → cache resulting `.mlmodelc` in `Application Support/`.

---

## Training recipe

Canonical details in `notebooks/training/2026-04-multi-garment.ipynb` once it's checked in.

- **Hardware:** 1× NVIDIA A100 40GB. Lambda Labs at $1.29/hr, Vast.ai interruptible at ~$0.79/hr, RunPod at $1.39/hr.
- **Epochs:** 6-12 (transformers fine-tune faster than CNNs).
- **Learning rate:** 1e-4 to 5e-5 with cosine decay.
- **Batch size:** 4-8 per GPU at 1024×1024 with mixed precision.
- **Wall clock:** ~30-50 GPU hours for one cycle. Budget $100-200 total including 2-3 hyperparam runs.
- **Target:** ≥30 mask mAP @ 0.5 IoU on the 6 collapsed superclasses. Per-class breakdown to spot weak points.

---

## Key references

- [RF-DETR repo](https://github.com/roboflow/rf-detr) (Apache 2.0)
- [RF-DETR-Seg blog announcement](https://blog.roboflow.com/rf-detr-segmentation/)
- [RF-DETR on iOS benchmark post](https://blog.roboflow.com/best-ios-object-detection-models/)
- [Fashionpedia data license](https://fashionpedia.github.io/home/data_license.html)
- [Fashionpedia CVDF host](https://github.com/cvdfoundation/fashionpedia)
- [Fashionpedia on HuggingFace](https://huggingface.co/datasets/detection-datasets/fashionpedia)
- [SAM 2 repo (Apache 2.0)](https://github.com/facebookresearch/sam2)
- [Apple CoreML SAM 2 collection](https://huggingface.co/collections/apple/core-ml-segment-anything-2)
- [Apple coreml-detr-semantic-segmentation](https://huggingface.co/apple/coreml-detr-semantic-segmentation)
- [ModaNet LICENSE (CC BY-NC 4.0)](https://github.com/eBay/modanet/blob/master/LICENSE) — ruled out
- [DeepFashion2 commercial-use issue](https://github.com/switchablenorms/DeepFashion2/issues/3) — ruled out
- [SegFormer NVIDIA license](https://github.com/NVlabs/SegFormer/blob/master/LICENSE) — ruled out
- [Ultralytics AGPL-3.0 license](https://www.ultralytics.com/license) — ruled out
- [coremltools Issue #2479 — Mask R-CNN RoIAlign](https://github.com/apple/coremltools/issues/2479)
- [Apple Background Assets docs](https://developer.apple.com/documentation/backgroundassets)
- [WWDC25 Apple-Hosted Background Assets](https://developer.apple.com/videos/play/wwdc2025/325/)
- [Core ML Palettization Overview](https://apple.github.io/coremltools/docs-guides/source/opt-palettization-overview.html)
- [Core ML Flexible Input Shapes](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html)
- [Apple ML Research: Deploying Transformers on ANE](https://machinelearning.apple.com/research/neural-engine-transformers)
- [Apple ML Research: HyperDETR](https://machinelearning.apple.com/research/panoptic-segmentation)
- [hollance/neural-engine — checking ANE residency](https://github.com/hollance/neural-engine/blob/master/docs/is-model-using-ane.md)
- [Apple: Downloading and Compiling a Model on Device](https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device)
- [WWDC23 Session 10049 — Async Core ML prediction](https://developer.apple.com/videos/play/wwdc2023/10049/)
- [WWDC24 Session 10159 — Bring your ML models to Apple silicon](https://developer.apple.com/videos/play/wwdc2024/10159/)
- [Photoroom Core ML benchmark 2023](https://www.photoroom.com/inside-photoroom/core-ml-performance-benchmark-2023-edition)
- [pointfreeco/swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
