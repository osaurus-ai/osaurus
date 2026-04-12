# Building Open-Source Software From Source: Lessons Learned

Universal principles distilled from building Osaurus — applicable any time you compile someone else's code.

---

## 1. Never trust the supply chain blindly

Every dependency is code you didn't write running with your privileges. Before building:

- Read the lockfile (`Package.resolved`, `package-lock.json`, `Cargo.lock`, `Gemfile.lock`). It tells you exactly what commits will be compiled. If there's no lockfile, every build pulls whatever's latest — walk away or pin things yourself.
- Verify that pinned commits match tagged releases on the upstream repos. Tags can be moved; commit SHAs can't. A tag pointing to a different commit than your lockfile expects is a red flag.
- Flag any dependency pinned to a branch instead of a version or commit. `branch: "main"` means the author (or anyone who compromises their repo) can change what you build at any time. Pin to the exact commit hash before compiling.
- Count your transitive dependencies. A project with 13 direct deps may resolve to 45+ total. Each one is an attack vector.

## 2. Lockfiles are the source of truth — but projects can have more than one

Some build systems maintain multiple lockfiles (SPM packages vs. Xcode workspace, npm workspaces, Cargo workspaces). They resolve independently and can drift apart. If you update one and not the other, your CLI build and your app build may compile different code.

Always find all lockfiles, understand which build path uses which, and keep them in sync.

## 3. Clean builds after changing dependencies

Compiled modules are cached aggressively. If you change a dependency version and rebuild without cleaning, you'll get cryptic errors about unresolved modules — old compiled artifacts referencing packages that no longer match. When in doubt, nuke the build cache and start fresh.

## 4. Code signing will block you on someone else's project

macOS and iOS projects are signed with the developer's team identity. You won't have their certificate. Expect this and know how to bypass it for local builds:

- Xcode CLI: `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- Xcode GUI: Change the team to your personal team or "Sign to Run Locally"

The resulting binary runs fine locally but can't be distributed.

## 5. Specialized toolchains may not be installed

Projects that use GPU compute (Metal, CUDA), cross-compilation, or platform-specific SDKs may need toolchain components that aren't part of the default developer tools install. These failures often look like missing executables rather than missing libraries. Read the error message — it usually tells you exactly what to install.

## 6. Slow compilation is not a broken build

GPU shader compilation, C++ template-heavy libraries, and large codebases can take 15-30+ minutes. If the build shows warnings but hasn't returned to your prompt, it's probably still working. Verify with process monitoring before killing it.

## 7. The code on main may not build with the pinned dependencies

Open-source projects frequently have their HEAD ahead of their last release. The code may call APIs that only exist in newer versions of dependencies than what the lockfile pins. When you hit a "no member" or "unresolved symbol" error on freshly cloned code, check whether a dependency needs to be bumped. Look at recent commits for clues.

## 8. Do your security audit before building, not after

Once you run `make` or `swift build` or `npm install`, build scripts and post-install hooks execute arbitrary code on your machine. The time to audit is before that first build command. Specifically look for:

- Build scripts that `curl` or `wget` binaries
- Post-install hooks that download executables
- `Process()` / `exec()` / `eval()` calls
- `dlopen` / dynamic library loading without verification
- Hardcoded IP addresses (potential C2 servers)
- Base64-encoded blobs (obfuscated payloads)

## 9. Understand what the binary links against after building

Run `otool -L` (macOS) or `ldd` (Linux) on the output binary. If you see unexpected dynamic libraries or rpaths pointing to unusual locations, investigate before running it. You can also sandbox the first execution to limit what it can access.

## 10. Document what you did

Build issues are almost always non-obvious the first time and completely forgettable by the second time. Write down what broke, what fixed it, and what order things need to happen. Your future self (or teammate) will thank you.
