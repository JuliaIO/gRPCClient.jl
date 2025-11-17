from black.trans import Callable

from test_pb2 import TestRequest, TestResponse
from test_pb2_grpc import TestServiceStub
import numpy as np
import grpc
import time
import os
import plac
import dataclasses
from concurrent.futures import ThreadPoolExecutor


channel = grpc.insecure_channel("localhost:8001")
stub = TestServiceStub(channel)
executor = ThreadPoolExecutor(max_workers=os.cpu_count())


@dataclasses.dataclass
class Benchmark:
    fn: Callable
    n_reqs: int


# Create the protobuf ahead of time so we only measure gRPC overhead as much as possible
SMOL_REQUEST = TestRequest(test_response_sz=1, data=np.zeros((1,), dtype=np.uint64))


def fn_smol(n):
    response = stub.TestRPC(SMOL_REQUEST)
    return response


BENCHMARKS = {"smol": Benchmark(fn_smol, 1000)}


@plac.opt("fn", "Benchmark name", choices=["smol"])
def bench(fn: str = "smol", n_trials: int = 30):

    benchmark = BENCHMARKS[fn]

    trials_time = []

    for i in range(n_trials):
        t_i = time.time()
        results_iterator = executor.map(benchmark.fn, range(benchmark.n_reqs))
        for response in results_iterator:
            pass
        t_f = time.time()
        trials_time.append(t_f - t_i)

    trials_time = np.array(trials_time)
    trials_time = trials_time / benchmark.n_reqs
    throughput = 1 / trials_time

    print(f"average: {'%.2f' % throughput.mean()} RPS")
    print(f"std: {'%.2f' % throughput.std()} RPS")
    print(f"min: {'%.2f' % throughput.min()} RPS")
    print(f"max: {'%.2f' % throughput.max()} RPS")


if __name__ == "__main__":
    plac.call(bench)
