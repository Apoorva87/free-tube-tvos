FROM node:22-bookworm-slim AS acquire
RUN npm install --prefix /opt/cli @openai/codex@0.172.0 \
 && cp "$(find /opt/cli/node_modules/@openai -type f -path '*/bin/codex' | head -1)" /usr/local/bin/codex \
 && /usr/local/bin/codex --version | grep -Fx 'codex-cli 0.172.0'

FROM python:3.13-slim-bookworm
COPY --from=acquire /usr/local/bin/codex /usr/local/bin/codex
COPY runner.py /policy/runner.py
RUN mkdir -p /work /session /policy /home/viewer \
 && chown 10001:10001 /session /home/viewer \
 && python /policy/runner.py build-catalog
ENV HOME=/home/viewer CODEX_HOME=/session PYTHONDONTWRITEBYTECODE=1
USER 10001:10001
WORKDIR /work
RUN --network=none python /policy/runner.py status | grep -F '"state": "signed_out"'
ENTRYPOINT ["python", "/policy/runner.py"]
