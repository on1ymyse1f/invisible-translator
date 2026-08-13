# Safari reuse path

Safari Web Extensions consume the same standards-based source in `../chromium`; there is intentionally no divergent Safari content-script implementation.

From Xcode's toolchain, create a local Safari wrapper project with:

```sh
xcrun safari-web-extension-converter ../chromium --project-location ./GeneratedSafariWrapper --app-name "Invisible Translator"
```

Review the generated app-extension entitlements and native-app bridge before signing. The converted extension must retain the exact manifest allow-list and must not add broad website access. Safari does not use Chrome Native Messaging directly, so its app-extension bridge must preserve the request/response contract in `../README.md` and must not provide a network fallback.
