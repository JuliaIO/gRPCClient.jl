package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"

	"google.golang.org/grpc"
)

type testServiceServer struct {
	UnimplementedTestServiceServer
	public bool
}

func newServer(public bool) *testServiceServer {
	return &testServiceServer{public: public}
}

// TestRPC implements the unary RPC
func (s *testServiceServer) TestRPC(ctx context.Context, req *TestRequest) (*TestResponse, error) {
	var responseData []uint64

	if !s.public {
		// For testing
		if req.TestResponseSz > 4*1024*1024/8 {
			return nil, fmt.Errorf(">:|")
		}
		responseData = make([]uint64, req.TestResponseSz)
		for i := uint64(0); i < req.TestResponseSz; i++ {
			responseData[i] = i + 1
		}
	} else {
		// For precompile
		responseData = []uint64{1}
	}

	return &TestResponse{Data: responseData}, nil
}

// TestClientStreamRPC implements the client streaming RPC
func (s *testServiceServer) TestClientStreamRPC(stream TestService_TestClientStreamRPCServer) error {
	rs := uint64(0)

	for {
		req, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		rs += req.TestResponseSz
	}

	var responseData []uint64
	if !s.public {
		// For testing
		responseData = make([]uint64, rs)
		for i := uint64(0); i < rs; i++ {
			responseData[i] = i + 1
		}
	} else {
		// For precompile
		responseData = []uint64{1}
	}

	return stream.SendAndClose(&TestResponse{Data: responseData})
}

// TestServerStreamRPC implements the server streaming RPC
func (s *testServiceServer) TestServerStreamRPC(req *TestRequest, stream TestService_TestServerStreamRPCServer) error {
	if !s.public {
		// For testing
		for i := uint64(1); i <= req.TestResponseSz; i++ {
			responseData := make([]uint64, i)
			for j := uint64(0); j < i; j++ {
				responseData[j] = j + 1
			}
			if err := stream.Send(&TestResponse{Data: responseData}); err != nil {
				return err
			}
		}
	} else {
		// For precompile
		responseData := []uint64{1}
		if err := stream.Send(&TestResponse{Data: responseData}); err != nil {
			return err
		}
	}

	return nil
}

// TestBidirectionalStreamRPC implements the bidirectional streaming RPC
func (s *testServiceServer) TestBidirectionalStreamRPC(stream TestService_TestBidirectionalStreamRPCServer) error {
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		var responseData []uint64
		if !s.public {
			responseData = make([]uint64, req.TestResponseSz)
			for i := uint64(0); i < req.TestResponseSz; i++ {
				responseData[i] = i + 1
			}
		} else {
			responseData = []uint64{1}
		}

		if err := stream.Send(&TestResponse{Data: responseData}); err != nil {
			return err
		}
	}
}

func main() {
	publicMode := flag.Bool("public", false, "run in public mode (response.data will always be length 1)")
	flag.Parse()

	host := "127.0.0.1"
	if envHost := os.Getenv("GRPC_TEST_SERVER_HOST"); envHost != "" {
		host = envHost
	}

	port := 8001
	if envPort := os.Getenv("GRPC_TEST_SERVER_PORT"); envPort != "" {
		var err error
		port, err = strconv.Atoi(envPort)
		if err != nil {
			log.Fatalf("Invalid GRPC_TEST_SERVER_PORT: %v", err)
		}
	}

	if *publicMode {
		host = "::"
		log.Printf("Listening on [%s]:%d in public mode", host, port)
		log.Println("(len(response.data) will always be 1)")
	} else {
		log.Printf("Listening on %s:%d in test mode", host, port)
	}

	bindAddress := fmt.Sprintf("%s:%d", host, port)
	lis, err := net.Listen("tcp", bindAddress)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	RegisterTestServiceServer(grpcServer, newServer(*publicMode))

	log.Printf("gRPC server started")
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}
