
from concurrent import futures
import logging

import numpy as np
import grpc
import test_pb2
import test_pb2_grpc
import sys
import os

class TestServiceServicer(test_pb2_grpc.TestServiceServicer):
    def __init__(self, public: bool = False):
        self.public = public

    def TestRPC(self, request: test_pb2.TestRequest, context):

        if not self.public:
            assert request.test_response_sz <= 4*1024*1024//8, ">:|"
            # For testing
            response_data = np.arange(request.test_response_sz, dtype=np.uint64)
            response_data[:] += 1
        else:
            # For precompile
            response_data = np.arange(1, dtype=np.uint64)
            response_data[:] += 1

        return test_pb2.TestResponse(data=response_data)

    def TestClientStreamRPC(self, request_iterator, context):
        rs = 0
        for request in request_iterator:
            rs += request.test_response_sz

        if not self.public:
            # For testing
            response_data = np.arange(rs, dtype=np.uint64)
            response_data[:] += 1
        else:
            # For precompile
            response_data = np.arange(1, dtype=np.uint64)
            response_data[:] += 1

        return test_pb2.TestResponse(data=response_data)

    def TestServerStreamRPC(self, request, context):

        if not self.public:
            # For testing
            for i in range(1, request.test_response_sz + 1):
                response_data = np.arange(i, dtype=np.uint64)
                response_data[:] += 1
                yield test_pb2.TestResponse(data=response_data)
        else:
            # For precompile
            response_data = np.arange(1, dtype=np.uint64)
            response_data[:] += 1

            yield test_pb2.TestResponse(data=response_data)


    def TestBidirectionalStreamRPC(self, request_iterator, context):
        for request in request_iterator:
            if not self.public:
                response_data = np.arange(request.test_response_sz, dtype=np.uint64)
                response_data[:] += 1
            else:
                response_data = np.arange(1, dtype=np.uint64)
                response_data[:] += 1

            yield test_pb2.TestResponse(data=response_data)


def serve(public: bool = False):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=12))
    test_pb2_grpc.add_TestServiceServicer_to_server(
        TestServiceServicer(public=public), server
    )
    if public:
        bind_address = "[::]:8001"
        logging.info("Listening on %s in public mode" % bind_address)
        logging.info("(len(response.data) will always be 1)")
        server.add_insecure_port(bind_address)
    else:
        host = '127.0.0.1' if 'GRPC_TEST_SERVER_HOST' not in os.environ else os.environ['GRPC_TEST_SERVER_HOST']
        port = 8001 if 'GRPC_TEST_SERVER_PORT' not in os.environ else int(os.environ['GRPC_TEST_SERVER_PORT'])
        bind_address = f"{host}:{port}"
        logging.info("Listening on %s in test mode" % bind_address)
        server.add_insecure_port(bind_address)

    server.start()

    if os.path.exists('/test/.healthcheck'):
        try:
            open('/test/.healthy', 'w')
        except:
            pass

    server.wait_for_termination()


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)
    serve(public=len(sys.argv) > 1 and sys.argv[1] == 'public')