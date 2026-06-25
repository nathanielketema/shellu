# Shellu

A simple shell implemented in zig for educational purposes.

## Start

```console
zig build run
```

Test could be run as:

```console
cd src
zig build test
```

You only need [zig](https://ziglang.org/) 0.16.0 to be able to run it.

## Implemented features

- [x] Background jobs
- [x] Command completion
- [x] Command History
- [x] Redirection
- [x] Pipes
- [x] Variables
- [x] Builtins
  - [x] cd
  - [x] pwd
  - [x] echo
  - [x] jobs
  - [x] type
  - [x] declare
  - [x] history
  - [x] exit
- [ ] Helpful errors
