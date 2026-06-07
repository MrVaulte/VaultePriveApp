# Contributing

## Local setup

1. Create your own relay or point the app to a development relay.
2. Copy `Secrets.example.xcconfig` to `Secrets.xcconfig`.
3. Keep `Secrets.xcconfig` out of git.
4. Provide the relay values through Xcode build settings or environment variables.

## Before opening a PR

- do not commit secrets
- do not commit build artifacts
- do not commit personal Xcode user data
- prefer small reviewable changes
- keep the luxury-minimal design direction: `ink`, `gold`, starfield, `AMTypewriter`

## Open source release checklist

Before publishing a public build or public repo:

- rotate any previously exposed relay secrets
- replace placeholder relay URL with your own deployment
- verify Apple signing and bundle settings
- confirm legal/privacy docs are correct for your deployment

