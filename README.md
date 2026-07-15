# XplainR

Desktop assistant for live transcription and technical explanations.

XplainR can transcribe live audio from the microphone, system audio, or both
sources at the same time. It stores sessions locally, supports transcript
search, term corrections, project-specific auto-corrections, transcript
translation, contextual explanations, and questions over the saved transcript.

## Transcription engines

XplainR supports two live transcription engines:

- Apple Speech, using the platform speech recognizer.
- Local WhisperKit, using a local OpenAI-compatible WhisperKit server.

When Local WhisperKit is selected, XplainR starts the local server
automatically if it is not already running:

```text
whisperkit-cli serve --host 127.0.0.1 --port 50060
```

The app sends audio chunks to:

```text
http://127.0.0.1:50060/v1/audio/transcriptions
```

## Dependencies

Required for the Local WhisperKit transcription engine:

- `whisperkit-cli` available on `PATH`, or
- `WHISPERKIT_CLI_PATH` pointing to the executable.

If the server is already running on port `50060`, XplainR reuses it. If XplainR
starts the server itself, it stops that managed process when the app closes.

## Development

```text
flutter analyze
flutter build macos
```
