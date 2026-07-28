# E2E tests

Live scenarios against a real sshd in Docker, with a real PTY (expect) and the real system clipboard (`pbcopy`/`pbpaste` — macOS only; run locally, not in CI).

## Setup

```bash
# sshd container with user `dev` and your key
docker run -d --name devbox-sshd -p 2222:2222 \
  -e USER_NAME=dev -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -e PASSWORD_ACCESS=false \
  lscr.io/linuxserver/openssh-server:latest

# fixture for the upload scenario
printf "hello-from-local-file" > /tmp/devbox-upload-me.txt

cargo build --release
```

## Run

```bash
tests/e2e.exp       target/release/devbox ~/.ssh/id_ed25519   # text, file, OSC 52, disconnect
tests/e2e-image.exp target/release/devbox ~/.ssh/id_ed25519   # clipboard image → PNG
```

`e2e-image.exp` needs an image in the clipboard first (⌘⇧⌃4, or any copied screenshot).

⚠ The tests overwrite the system clipboard and add a `[127.0.0.1]:2222` entry to `~/.ssh/known_hosts`.

## Cleanup

```bash
docker rm -f devbox-sshd
ssh-keygen -R "[127.0.0.1]:2222"
rm /tmp/devbox-upload-me.txt
```
