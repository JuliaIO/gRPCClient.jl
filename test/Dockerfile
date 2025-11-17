FROM debian:trixie

# Need curl to install uv
RUN apt-get update
RUN apt-get install -y curl 

# Install uv so we can easily install dependencies for the gRPC test server
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
# Add uv to PATH
ENV PATH=$PATH:/root/.local/bin

# Add all files needed for testing
RUN mkdir /test 

COPY python/.python-version /test
COPY python/grpc_test_server.py /test
COPY python/pyproject.toml /test
COPY python/test_pb2_grpc.py /test
COPY python/test_pb2.py /test
COPY python/test_pb2.pyi /test
COPY python/uv.lock /test

RUN cd /test && uv sync

COPY python/entrypoint.sh /test
RUN touch /test/.healthcheck

ENV GRPC_TEST_SERVER_HOST=0.0.0.0
ENV GRPC_TEST_SERVER_PORT=8001

ENTRYPOINT /test/entrypoint.sh
HEALTHCHECK --interval=1s CMD bash -c '[ -e /test/.healthy ]' || exit 1