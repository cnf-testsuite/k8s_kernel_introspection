require "sam"
require "file_utils"
require "colorize"
require "totem"
require "./utils/utils.cr"
require "retriable"

desc "Install Kind"
task "install_kind" do |_, args|
  Log.info {"install_kind"}
  current_dir = FileUtils.pwd 
  unless Dir.exists?("#{current_dir}/#{TOOLS_DIR}/kind")
    FileUtils.mkdir_p("#{current_dir}/#{TOOLS_DIR}/kind") 
    write_file = "#{current_dir}/#{TOOLS_DIR}/kind/kind"
    Log.info { "write_file: #{write_file}" }
    if args.named["offline"]?
        Log.info { "install kind offline mode" }
        FileUtils.cp("#{TarClient::TAR_DOWNLOAD_DIR}/kind", "#{write_file}")
      stderr = IO::Memory.new
      status = Process.run("chmod +x #{write_file}", shell: true, output: stderr, error: stderr)
      success = status.success?
      raise "Unable to make #{write_file} executable" if success == false
    else
      Log.info { "install kind online mode" }
      url = "https://github.com/kubernetes-sigs/kind/releases/download/v#{KIND_VERSION}/kind-linux-amd64"
      Log.info { "url: #{url}" }
      do_this_on_each_retry = ->(ex : Exception, attempt : Int32, elapsed_time : Time::Span, next_interval : Time::Span) do
          Log.info { "#{ex.class}: '#{ex.message}' - #{attempt} attempt in #{elapsed_time} seconds and #{next_interval} seconds until the next try."}
      end
      Retriable.retry(on_retry: do_this_on_each_retry, times: 3, base_interval: 1.second) do
        resp = Halite.follow.get("#{url}") do |response| 
          File.write("#{write_file}", response.body_io)
        end 
        Log.debug {"resp: #{resp}"}
        case resp.status_code
        when 403, 404
          raise "Unable to download: #{url}" 
        end
        stderr = IO::Memory.new
        status = Process.run("chmod +x #{write_file}", shell: true, output: stderr, error: stderr)
        success = status.success?
        raise "Unable to make #{write_file} executable" if success == false
      end
    end
  end
end

desc "Uninstall Kind"
task "uninstall_kind" do |_, args|
  current_dir = FileUtils.pwd 
  Log.for("verbose").info { "uninstall_kind" } if check_verbose(args)
  FileUtils.rm_rf("#{current_dir}/#{TOOLS_DIR}/kind")
end

desc "Install Kind/Calico"
task "create_kind_calico" do |_, args|
  Log.info { "Creating Kind/Calico Cluster" }
  KindManager.create_cluster("calico-test", "projectcalico/tigera-operator")
end

desc "Install Kind/Cilium"
task "create_kind_cilium" do |_, args|
  Log.info { "Creating Kind/Cilium Cluster" }
  KindManager.create_cluster("cilium-test", "cilium/cilium --version 1.10.5 --set operator.replicas=1")
end

desc "Delete Cluster"
task "delete_test_clusters" do |_, arg|
  KindManager.delete_cluster("calico-test")
  KindManager.delete_cluster("cilium-test")
end

module KindManager
  def self.delete_cluster(name)
    Log.info {"Deleting Kind Cluster: #{name}"}
    `kind delete cluster --name #{name}`
    current_dir = FileUtils.pwd 
    File.delete "#{current_dir}/#{TOOLS_DIR}/kind/#{name}_admin.conf"
  end

  #totod make a create cluster with flannel

  def self.create_cluster(name, cni_plugin)
    Log.info {"Creating Kind Cluster"}
    current_dir = FileUtils.pwd 
    helm = BinarySingleton.helm
    kind = "#{current_dir}/#{TOOLS_DIR}/kind/kind"
    kubeconfig = "#{current_dir}/#{TOOLS_DIR}/kind/#{name}_admin.conf"
    File.write("disable_cni.yml", DISABLE_CNI)
    unless File.exists?("#{kubeconfig}")
      `#{kind} create cluster --name #{name} --config disable_cni.yml --kubeconfig #{kubeconfig}`
    end
    Log.info {`#{helm} install #{name}-plugin #{cni_plugin} --namespace kube-system --kubeconfig #{kubeconfig}`}
    wait_for_cluster(kubeconfig)
  end

  def self.wait_for_cluster(kubeconfig, wait_count : Int32 = 180)
    Log.info { "wait_for_cluster" }
    ready = false
    timeout = wait_count
    until (ready == true || timeout <= 0) 
      all_pods = `kubectl get pods --namespace=kube-system  --kubeconfig #{kubeconfig}`
      Log.info { "all_pods: #{all_pods}" }
      pod_count  = all_pods.split("\n").reduce(0) {|acc,x| acc+1}
      Log.info { "pod_count: #{pod_count}" }

cmd = <<-STRING 
kubectl -n kube-system get pods -o go-template='{{range $index, $element := .items}}{{range .status.containerStatuses}}{{if .ready}}{{$element.metadata.name}}{{"\\n"}}{{end}}{{end}}{{end}}'  --kubeconfig #{kubeconfig}
STRING

      Log.info { "cmd: #{cmd}" }
      ready_pods = `#{cmd}`
      Log.info { "ready_pods: #{ready_pods}" }
      ready_count  = ready_pods.split("\n").reduce(0) {|acc,x| acc+1}
      Log.info { "ready_count: #{ready_count}" }

      header_count = 1
      if (pod_count.to_i - header_count) == ready_count.to_i
        Log.info { "Cluster installed" }
        ready = true
      end
      sleep 1
      timeout = timeout - 1 
      LOGGING.info "Waitting for CRI-Tools Pod"
      if timeout <= 0
        break
      end
    end
    ready
  end

end

