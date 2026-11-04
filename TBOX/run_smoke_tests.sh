#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
MODULE_CACHE="${TMPDIR:-/tmp}/tbox_test_module_cache"
OUT="${TMPDIR:-/tmp}/tbox_image_processing_smoke"

mkdir -p "$MODULE_CACHE"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -o "$OUT" \
  "$PROJECT_DIR/TBOX/Support/ImageProcessing.swift" \
  "$PROJECT_DIR/Tests/ImageProcessingSmoke/main.swift"

"$OUT"

SEGMENTER_OUT="${TMPDIR:-/tmp}/tbox_transcription_segmenter_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  -framework ScreenCaptureKit \
  -o "$SEGMENTER_OUT" \
  "$PROJECT_DIR/TBOX/Support/Logger.swift" \
  "$PROJECT_DIR/TBOX/Recording/WhisperKitTranscriptionEngine.swift" \
  "$PROJECT_DIR/TBOX/Recording/SpeakerDiarizer.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptionAligner.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptPolisher.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingTranscriptionManager.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingAudioArchiver.swift" \
  "$PROJECT_DIR/TBOX/Recording/SystemAudioRecorder.swift" \
  "$PROJECT_DIR/TBOX/Recording/AudioTrackMixer.swift" \
  "$PROJECT_DIR/Tests/TranscriptionSegmenterSmoke/main.swift"

"$SEGMENTER_OUT"

PERSISTENCE_OUT="${TMPDIR:-/tmp}/tbox_transcript_persistence_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  -framework ScreenCaptureKit \
  -o "$PERSISTENCE_OUT" \
  "$PROJECT_DIR/TBOX/Support/Logger.swift" \
  "$PROJECT_DIR/TBOX/Recording/WhisperKitTranscriptionEngine.swift" \
  "$PROJECT_DIR/TBOX/Recording/SpeakerDiarizer.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptionAligner.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptPolisher.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingTranscriptionManager.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingAudioArchiver.swift" \
  "$PROJECT_DIR/TBOX/Recording/SystemAudioRecorder.swift" \
  "$PROJECT_DIR/TBOX/Recording/AudioTrackMixer.swift" \
  "$PROJECT_DIR/Tests/TranscriptPersistenceSmoke/main.swift"

"$PERSISTENCE_OUT"

SPEAKER_OUT="${TMPDIR:-/tmp}/tbox_speaker_pipeline_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  -framework ScreenCaptureKit \
  -o "$SPEAKER_OUT" \
  "$PROJECT_DIR/TBOX/Support/Logger.swift" \
  "$PROJECT_DIR/TBOX/Recording/WhisperKitTranscriptionEngine.swift" \
  "$PROJECT_DIR/TBOX/Recording/SpeakerDiarizer.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptionAligner.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptPolisher.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingTranscriptionManager.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingAudioArchiver.swift" \
  "$PROJECT_DIR/TBOX/Recording/SystemAudioRecorder.swift" \
  "$PROJECT_DIR/TBOX/Recording/AudioTrackMixer.swift" \
  "$PROJECT_DIR/Tests/SpeakerPipelineSmoke/main.swift"

"$SPEAKER_OUT"

RESULT_WINDOW_OUT="${TMPDIR:-/tmp}/tbox_transcription_result_window_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  -framework ScreenCaptureKit \
  -o "$RESULT_WINDOW_OUT" \
  "$PROJECT_DIR/TBOX/Support/Logger.swift" \
  "$PROJECT_DIR/TBOX/Recording/WhisperKitTranscriptionEngine.swift" \
  "$PROJECT_DIR/TBOX/Recording/SpeakerDiarizer.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptionAligner.swift" \
  "$PROJECT_DIR/TBOX/Recording/TranscriptPolisher.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingTranscriptionManager.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingAudioArchiver.swift" \
  "$PROJECT_DIR/TBOX/Recording/SystemAudioRecorder.swift" \
  "$PROJECT_DIR/TBOX/Recording/AudioTrackMixer.swift" \
  "$PROJECT_DIR/TBOX/Recording/RecordingTranscriptionResultWindow.swift" \
  "$PROJECT_DIR/Tests/TranscriptionResultWindowSmoke/main.swift"

"$RESULT_WINDOW_OUT"

MIXER_OUT="${TMPDIR:-/tmp}/tbox_audio_track_mixer_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AVFoundation \
  -o "$MIXER_OUT" \
  "$PROJECT_DIR/TBOX/Support/Logger.swift" \
  "$PROJECT_DIR/TBOX/Recording/AudioTrackMixer.swift" \
  "$PROJECT_DIR/Tests/AudioTrackMixerSmoke/main.swift"

"$MIXER_OUT"

TEXT_OUT="${TMPDIR:-/tmp}/tbox_text_recognition_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework Vision \
  -o "$TEXT_OUT" \
  "$PROJECT_DIR/TBOX/Text/TextRecognitionService.swift" \
  "$PROJECT_DIR/Tests/TextRecognitionSmoke/main.swift"

"$TEXT_OUT"

DIRECTION_OUT="${TMPDIR:-/tmp}/tbox_translation_direction_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -o "$DIRECTION_OUT" \
  "$PROJECT_DIR/Tests/TranslationDirectionSmoke/main.swift"

"$DIRECTION_OUT"

HOVER_OUT="${TMPDIR:-/tmp}/tbox_hover_tooltip_smoke"
swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -warnings-as-errors \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Vision \
  -framework NaturalLanguage \
  -framework Translation \
  -framework CoreImage \
  -o "$HOVER_OUT" \
  "$PROJECT_DIR/TBOX/Capture/OverlayPanel.swift" \
  "$PROJECT_DIR/TBOX/Text/TextRecognitionService.swift" \
  "$PROJECT_DIR/TBOX/Text/TranslationBridge.swift" \
  "$PROJECT_DIR/TBOX/Text/TextResultPanel.swift" \
  "$PROJECT_DIR/TBOX/Annotation/AnnotationCanvas.swift" \
  "$PROJECT_DIR/TBOX/Annotation/AnnotationElement.swift" \
  "$PROJECT_DIR/TBOX/Support/Logger.swift" \
  "$PROJECT_DIR/TBOX/Support/Extensions.swift" \
  "$PROJECT_DIR/TBOX/Support/ImageProcessing.swift" \
  "$PROJECT_DIR/Tests/HoverTooltipSmoke/main.swift"

"$HOVER_OUT"
