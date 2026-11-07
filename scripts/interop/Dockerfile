# The Kit's test image plus Python, for the Reticulum/LXMF interop tests (MESHSAT_INTEROP=1): the same
# toolchain CI tests with, and the python3 the pinned RNS/LXMF venv is made from. Built and run by
# scripts/interop-docker.sh on a developer machine or the runner; CI never runs the interop tests.
FROM swift:6.2-noble
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv python3-pip iproute2 \
    && rm -rf /var/lib/apt/lists/*
