#include "ProtocBuf.h"
#include <iostream>
#include <grpcpp/grpcpp.h>
#include "instrumentation.grpc.pb.h"

#define DEBUG_TYPE "ProtocBuf"

using namespace ca::uoft::drsg::bminstrument::communication;

using grpc::Channel;
using grpc::ClientContext;
using grpc::Status;


std::vector<InstrumentationRule> instrumentationRules;

extern int clientSocket;

class InstrumentationPlanClient {
public:
    InstrumentationPlanClient(std::shared_ptr<Channel> channel)
        : stub_(InstrumentationManager::NewStub(channel)) {}

    void send(InstrumentationPlan& instrumentationPlan) {
       
        PlanReply response;

        ClientContext context;
        Status status = stub_->AddPlan(&context, instrumentationPlan, &response);

        if (status.ok()) {
            std::cout << response.msg() << std::endl;
        } else {
            std::cout << "RPC failed with status code: " << status.error_code()
                      << ", error message: " << status.error_message() << std::endl;
        }
    }

private:
    std::unique_ptr<InstrumentationManager::Stub> stub_;
};


void sendGRPC(InstrumentationPlan& instrumentationPlan) {
  std::string server_address("0.0.0.0:8088");
  InstrumentationPlanClient client(grpc::CreateChannel(server_address,
                            grpc::InsecureChannelCredentials())
                            );
  client.send(instrumentationPlan);
}


void sendSerializedNetwork(std::string &serialized_data) {
  // Send the serialized data to the server
  ssize_t bytesSent =
      write(clientSocket, serialized_data.c_str(), serialized_data.length());
  if (bytesSent == -1) {
    std::cerr << "the file descriptor is: " << clientSocket << "\n";
    std::cerr << "Failed to send message to server: " << strerror(errno)
              << std::endl;
    close(clientSocket); // Close the client socket before returning
    assert(false);
  }

  std::cout << "Instrumentation plan is sent to server." << std::endl;
}

void sendSerializedFileSystem(std::string &serialized_data) {
  // Open the file in binary mode
  std::ofstream file("data.bin", std::ios::binary);
  if (!file) {
    // Handle file open error
    assert(false && "failed to open data.bin");
  }

  // Write the serialized data to the file
  file.write(serialized_data.c_str(), serialized_data.size());

  // Close the file
  file.close();
}

int protocBufSerialization() {
    
  std::cout << "\nEnter protoc buffer serialization stage:\n\n";

  InstrumentationPlan instrumentationPlan;

  // add each instrumentation rule to the instrumentation plan
  for (const InstrumentationRule &instrumentationRule : instrumentationRules) {
    InstrumentationRule *newInstrumentationRule =
        instrumentationPlan.add_instrumentationrules();
    newInstrumentationRule->set_id(instrumentationRule.id());
    newInstrumentationRule->set_strategy(instrumentationRule.strategy());
    newInstrumentationRule->set_classname(instrumentationRule.classname());
    newInstrumentationRule->set_methodname(instrumentationRule.methodname());
    int index = 0;
    for (const auto &parameterType : instrumentationRule.parametertypes()) {
      newInstrumentationRule->add_parametertypes();
      newInstrumentationRule->set_parametertypes(index, parameterType);
      index++;
    }
    newInstrumentationRule->set_location(instrumentationRule.location());
    newInstrumentationRule->set_linenumber(instrumentationRule.linenumber());
    newInstrumentationRule->set_bytecodeindex(
        instrumentationRule.bytecodeindex());
    newInstrumentationRule->set_loopid(instrumentationRule.loopid());
  }

  // Serialize the AddressBook message
  std::string serialized_data;
  if (!instrumentationPlan.SerializeToString(&serialized_data)) {
    std::cerr << "Failed to serialize AddressBook." << std::endl;
    return 1;
  }

  // send the serialized data through some communication means:
  // disk/network/etc...
  // sendSerializedNetwork(serialized_data);
  // sendSerializedFileSystem(serialized_data);
  // sendGRPC(instrumentationPlan);
  // std::cout << "serialized data is: " << serialized_data << "\n";

  // Display the deserialized data for debugging purpose
  dbgs() << "\nDeserialized message: "
         << instrumentationPlan.DebugString() << "\n";

  return 0;
}
