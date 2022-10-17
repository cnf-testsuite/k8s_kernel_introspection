require "./spec_helper"
require "kubectl_client"
require "./../src/kernel_introspection.cr"
require "file_utils"

describe "KernelInstrospection" do
  before_all do
    ClusterTools.install
  end

  it "'#status_by_proc' should return all statuses for all containers in a pod", tags: ["kernel-introspection"] do
    result = KubectlClient::ShellCmd.run("kubectl run nginx --image=nginx --labels='name=nginx'", "kubectl_run", force_output=true)
    pods = KubectlClient::Get.pods_by_nodes(KubectlClient::Get.schedulable_nodes_list)
    pods.should_not be_nil
    pods = KubectlClient::Get.pods_by_label(pods, "name", "nginx")
    pods.should_not be_nil

    KubectlClient::Get.resource_wait_for_install("pod", "nginx")
    pods.size.should be > 0
    first_node = pods[0]
    statuses = KernelIntrospection::K8s.status_by_proc(first_node.dig("metadata", "name"), "nginx")
    Log.info { "process-statuses: #{statuses}" }
    (statuses).should_not be_nil

    (statuses.find{|x| x["cmdline"].includes?("nginx: master process")} ).should_not be_nil
  end

  # it "'#find_first_process' should return all statuses for all containers in a pod", tags: ["kernel-introspection"]  do
  #   # KubectlClient::Apply.namespace(TESTSUITE_NAMESPACE)
  #   begin
  #     LOGGING.info `./cnf-testsuite cnf_setup cnf-path=sample-cnfs/sample_coredns`
  #     # Dockerd.install
  #     pod_info = KernelIntrospection::K8s.find_first_process("coredns")
  #     Log.info { "pod_info: #{pod_info}"}
  #     (pod_info).should_not be_nil
  #   ensure
  #     LOGGING.info `./cnf-testsuite cnf_cleanup cnf-path=sample-cnfs/sample_coredns`
  #     $?.success?.should be_true
  #   end
  # end

end

