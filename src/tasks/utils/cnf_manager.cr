# coding: utf-8
require "totem"
require "colorize"
require "./types/cnf_conformance_yml_type.cr"
require "./helm.cr"
require "uuid"

module CNFManager 

  module Points
    def self.points_yml
      # TODO get points.yml from remote http
      points = File.open("points.yml") do |f| 
        YAML.parse(f)
      end 
      # LOGGING.debug "points: #{points.inspect}"
      points.as_a
    end
    def self.create_points_yml
      unless File.exists?("#{POINTSFILE}")
        branch = ENV.has_key?("SCORING_ENV") ? ENV["SCORING_ENV"] : "master"
        default_scoring_yml = "https://raw.githubusercontent.com/cncf/cnf-conformance/#{branch}/scoring_config/#{DEFAULT_POINTSFILENAME}"
        `wget #{ENV.has_key?("SCORING_YML") ? ENV["SCORING_YML"] : default_scoring_yml}`
        `mv #{DEFAULT_POINTSFILENAME} #{POINTSFILE}`
      end
    end

    def self.create_final_results_yml_name
      FileUtils.mkdir_p("results") unless Dir.exists?("results")
      "results/cnf-conformance-results-" + Time.local.to_s("%Y%m%d-%H%M%S-%L") + ".yml"
    end

    def self.clean_results_yml(verbose=false)
      if File.exists?("#{CNFManager::Points::Results.file}")
        results = File.open("#{CNFManager::Points::Results.file}") do |f| 
          YAML.parse(f)
        end 
        File.open("#{CNFManager::Points::Results.file}", "w") do |f| 
          YAML.dump({name: results["name"],
                     status: results["status"],
                     exit_code: results["exit_code"],
                     points: results["points"],
                     items: [] of YAML::Any}, f)
        end 
      end
    end

    def self.task_points(task, passed=true)
      if passed
        field_name = "pass"
      else
        field_name = "fail"
      end
      points =CNFManager::Points.points_yml.find {|x| x["name"] == task}
      LOGGING.warn "****Warning**** task #{task} not found in points.yml".colorize(:yellow) unless points
      if points && points[field_name]? 
          points[field_name].as_i if points
      else
        points =CNFManager::Points.points_yml.find {|x| x["name"] == "default_scoring"}
        points[field_name].as_i if points
      end
    end

    def self.total_points(tag=nil)
      if tag
        tasks = CNFManager::Points.tasks_by_tag(tag)
      else
        tasks = CNFManager::Points.all_task_test_names
      end
      yaml = File.open("#{CNFManager::Points::Results.file}") do |file|
        YAML.parse(file)
      end
      yaml["items"].as_a.reduce(0) do |acc, i|
        if i["points"].as_i? && i["name"].as_s? &&
            tasks.find{|x| x == i["name"]}
          (acc + i["points"].as_i)
        else
          acc
        end
      end
    end

    def self.total_max_points(tag=nil)
      if tag
        tasks = CNFManager::Points.tasks_by_tag(tag)
      else
        tasks = CNFManager::Points.all_task_test_names
      end
      tasks.reduce(0) do |acc, x|
        points = CNFManager::Points.task_points(x)
        if points
          acc + points
        else
          acc
        end
      end
    end

    def self.upsert_task(task, status, points) 
      results = File.open("#{CNFManager::Points::Results.file}") do |f| 
        YAML.parse(f)
      end 

      result_items = results["items"].as_a
      # remove the existing entry
      result_items = result_items.reject do |x| 
        x["name"] == task  
      end

      result_items << YAML.parse "{name: #{task}, status: #{status}, points: #{points}}"
      File.open("#{CNFManager::Points::Results.file}", "w") do |f| 
        YAML.dump({name: results["name"],
                   status: results["status"],
                   points: results["points"],
                   exit_code: results["exit_code"],
                   items: result_items}, f)
      end 
    end

    def self.failed_task(task, msg)
      CNFManager::Points.upsert_task(task, FAILED, CNFManager::Points.task_points(task, false))
      stdout_failure "#{msg}"
    end

    def self.passed_task(task, msg)
      CNFManager::Points.upsert_task(task, PASSED, CNFManager::Points.task_points(task))
      stdout_success "#{msg}"
    end

    def self.failed_required_tasks
      yaml = File.open("#{CNFManager::Points::Results.file}") do |file|
        YAML.parse(file)
      end
      yaml["items"].as_a.reduce([] of String) do |acc, i|
        if i["status"].as_s == "failed" && 
            i["name"].as_s? && 
            CNFManager::Points.task_required(i["name"].as_s)
          (acc << i["name"].as_s)
        else
          acc
        end
      end
    end

    def self.task_required(task)
      points =CNFManager::Points.points_yml.find {|x| x["name"] == task}
      LOGGING.warn "task #{task} not found in points.yml".colorize(:yellow) unless points
      if points && points["required"]? && points["required"].as_bool == true
        true
      else
        false
      end
    end

    def self.all_task_test_names
      result_items =CNFManager::Points.points_yml.reduce([] of String) do |acc, x|
        if x["name"].as_s == "default_scoring" ||
            x["tags"].as_s.split(",").find{|x|x=="platform"}
          acc
        else
          acc << x["name"].as_s
        end
      end
    end

    def self.tasks_by_tag(tag)
      #TODO cross reference points.yml tags with results
      found = false
      result_items =CNFManager::Points.points_yml.reduce([] of String) do |acc, x|
        if x["tags"].as_s? && x["tags"].as_s.includes?(tag)
          acc << x["name"].as_s
        else
          acc
        end
      end
    end

    def self.all_result_test_names(results_file)
      results = File.open(results_file) do |f| 
        YAML.parse(f)
      end 
      result_items = results["items"].as_a.reduce([] of String) do |acc, x|
        acc << x["name"].as_s
      end
    end

    def self.results_by_tag(tag)
      task_list = tasks_by_tag(tag)

      results = File.open("#{CNFManager::Points::Results.file}") do |f| 
        YAML.parse(f)
      end 

      found = false
      result_items = results["items"].as_a.reduce([] of YAML::Any) do |acc, x|
        if x["name"].as_s? && task_list.find{|tl| tl == x["name"].as_s}
          acc << x
        else
          acc
        end
      end
    end

    class Results
      @@file : String
      @@file = CNFManager::Points.create_final_results_yml_name
      LOGGING.info "CNFManager::Points::Results.file"
      continue = false
      LOGGING.info "file exists?:#{File.exists?(@@file)}"
      if File.exists?("#{@@file}")
        stdout_info "Do you wish to overwrite the #{@@file} file? If so, your previous results.yml will be lost."
        print "(Y/N) (Default N): > "
        if ENV["CRYSTAL_ENV"]? == "TEST"
          continue = true
        else
          user_input = gets
          if user_input == "Y" || user_input == "y"
            continue = true
          end
        end
      else
        continue = true
      end
      if continue
        File.open("#{@@file}", "w") do |f|
          YAML.dump(CNFManager::Points.template_results_yml, f)
        end
      end
      def self.file
        @@file
      end
    end

    def self.template_results_yml
  #TODO add tags for category summaries
  YAML.parse <<-END
name: cnf conformance 
status: 
points: 
exit_code: 0
items: []
END
    end
  end

  module Task
    def self.task_runner(args, &block : Sam::Args, CNFManager::Config -> String | Colorize::Object(String) | Nil)
      LOGGING.info("task_runner args: #{args.inspect}")
      if check_cnf_config(args)
        CNFManager::Task.single_task_runner(args, &block)
      else
        CNFManager::Task.all_cnfs_task_runner(args, &block)
      end
    end

    # TODO give example for calling
    def CNFManager::Task.all_cnfs_task_runner(args, &block : Sam::Args, CNFManager::Config  -> String | Colorize::Object(String) | Nil)

      # Platforms tests dont have any cnfs
      if CNFManager.cnf_config_list(silent: true).size == 0
        CNFManager::Task.single_task_runner(args, &block)
      else
        CNFManager.cnf_config_list(silent: true).map do |x|
          new_args = Sam::Args.new(args.named, args.raw)
          new_args.named["cnf-config"] = x
          CNFManager::Task.single_task_runner(new_args, &block)
        end
      end
    end
    # TODO give example for calling
    def CNFManager::Task.single_task_runner(args, &block : Sam::Args, CNFManager::Config -> String | Colorize::Object(String) | Nil)
      LOGGING.debug("single_task_runner args: #{args.inspect}")
      begin
        if args.named["cnf-config"]? # platform tests don't have a cnf-config
            config = CNFManager::Config.parse_config_yml(args.named["cnf-config"].as(String))    
        else
          config = CNFManager::Config.new({ destination_cnf_dir: "",
                                            source_cnf_file: "",
                                            source_cnf_dir: "",
                                            yml_file_path: "",
                                            install_method: {:helm_chart, ""},
                                            manifest_directory: "",
                                            helm_directory: "", 
                                            helm_chart_path: "", 
                                            manifest_file_path: "",
                                            git_clone_url: "",
                                            install_script: "",
                                            release_name: "",
                                            service_name: "",
                                            docker_repository: "",
                                            helm_repository: {name: "", repo_url: ""},
                                            helm_chart: "",
                                            helm_chart_container_name: "",
                                            rolling_update_tag: "",
                                            container_names: [{"name" =>  "", "rolling_update_test_tag" => ""}],
                                            white_list_container_names: [""]} )
        end
        yield args, config
      rescue ex
        # Set exception key/value in results
        # file to -1
        update_yml("#{CNFManager::Points::Results.file}", "exit_code", "1")
        LOGGING.error ex.message
        ex.backtrace.each do |x|
          LOGGING.error x
        end
      end
    end
  end

  class Config
    def initialize(cnf_config)
      @cnf_config = cnf_config 
    end
    property cnf_config : NamedTuple(destination_cnf_dir: String,
                                     source_cnf_file: String,
                                     source_cnf_dir: String,
                                     yml_file_path: String,
                                     install_method: Tuple(Symbol, String),
                                     manifest_directory: String,
                                     helm_directory: String, 
                                     helm_chart_path: String, 
                                     manifest_file_path: String, 
                                     git_clone_url: String,
                                     install_script: String,
                                     release_name: String,
                                     service_name:  String,
                                     docker_repository: String,
                                     helm_repository: NamedTuple(name:  String, 
                                                                 repo_url:  String) | Nil,
                                     helm_chart:  String,
                                     helm_chart_container_name: String,
                                     rolling_update_tag: String,
                                     container_names: Array(Hash(String, String )) | Nil,
                                     white_list_container_names: Array(String)) 

    def self.parse_config_yml(config_yml_path : String) : CNFManager::Config
      LOGGING.debug "parse_config_yml config_yml_path: #{config_yml_path}"
      yml_file = CNFManager.ensure_cnf_conformance_yml_path(config_yml_path)
      config = CNFManager.parsed_config_file(yml_file)

      install_method = CNFManager.cnf_installation_method(config)

      CNFManager.generate_and_set_release_name(config_yml_path)

      destination_cnf_dir = CNFManager.cnf_destination_dir(yml_file)

      yml_file_path = CNFManager.ensure_cnf_conformance_dir(config_yml_path)
      source_cnf_file = yml_file
      source_cnf_dir = yml_file_path
      manifest_directory = optional_key_as_string(config, "manifest_directory")
      if config["helm_repository"]?
          helm_repository = config["helm_repository"].as_h
        helm_repo_name = optional_key_as_string(helm_repository, "name")
        helm_repo_url = optional_key_as_string(helm_repository, "repo_url")
      else
        helm_repo_name = ""
        helm_repo_url = ""
      end
      helm_chart = optional_key_as_string(config, "helm_chart")
      release_name = optional_key_as_string(config, "release_name")
      service_name = optional_key_as_string(config, "service_name")
      helm_directory = optional_key_as_string(config, "helm_directory")
      git_clone_url = optional_key_as_string(config, "git_clone_url")
      install_script = optional_key_as_string(config, "install_script")
      docker_repository = optional_key_as_string(config, "docker_repository")
      if helm_directory.empty?
        working_chart_directory = "exported_chart"
      else
        working_chart_directory = helm_directory
      end
      helm_chart_path = destination_cnf_dir + "/" + working_chart_directory 
      manifest_file_path = destination_cnf_dir + "/" + "temp_template.yml"
      white_list_container_names = config.get("white_list_helm_chart_container_names").as_a.map do |c|
        "#{c.as_s?}"
      end
      container_names_totem = config["container_names"]
      container_names = container_names_totem.as_a.map do |container|
        {"name" => optional_key_as_string(container, "name"),
         "rolling_update_test_tag" => optional_key_as_string(container, "rolling_update_test_tag"),
         "rolling_downgrade_test_tag" => optional_key_as_string(container, "rolling_downgrade_test_tag"),
         "rolling_version_change_test_tag" => optional_key_as_string(container, "rolling_version_change_test_tag"),
         "rollback_from_tag" => optional_key_as_string(container, "rollback_from_tag"),
         }
      end

      CNFManager::Config.new({ destination_cnf_dir: destination_cnf_dir,
                               source_cnf_file: source_cnf_file,
                               source_cnf_dir: source_cnf_dir,
                               yml_file_path: yml_file_path,
                               install_method: install_method,
                               manifest_directory: manifest_directory,
                               helm_directory: helm_directory, 
                               helm_chart_path: helm_chart_path, 
                               manifest_file_path: manifest_file_path,
                               git_clone_url: git_clone_url,
                               install_script: install_script,
                               release_name: release_name,
                               service_name: service_name,
                               docker_repository: docker_repository,
                               helm_repository: {name: helm_repo_name, repo_url: helm_repo_url},
                               helm_chart: helm_chart,
                               helm_chart_container_name: "",
                               rolling_update_tag: "",
                               container_names: container_names,
                               white_list_container_names: white_list_container_names })

    end
  end

  # Applies a block to each cnf resource
  #
  # `CNFManager.cnf_workload_resources(args, config) {|cnf_config, resource| #your code}
  def self.cnf_workload_resources(args, config, &block)
    destination_cnf_dir = config.cnf_config[:destination_cnf_dir]
    yml_file_path = config.cnf_config[:yml_file_path] 
    helm_directory = config.cnf_config[:helm_directory]
    manifest_directory = config.cnf_config[:manifest_directory] 
    release_name = config.cnf_config[:release_name]
    helm_chart_path = config.cnf_config[:helm_chart_path]
    manifest_file_path = config.cnf_config[:manifest_file_path]
    test_passed = true
    if release_name.empty? # no helm chart
      template_ymls = Helm::Manifest.manifest_ymls_from_file_list(Helm::Manifest.manifest_file_list( destination_cnf_dir + "/" + manifest_directory))
    else
      Helm.generate_manifest_from_templates(release_name, 
                                            helm_chart_path, 
                                            manifest_file_path)
      template_ymls = Helm::Manifest.parse_manifest_as_ymls(manifest_file_path) 
    end
    resource_ymls = Helm.all_workload_resources(template_ymls)
		resource_resp = resource_ymls.map do | resource |
      resp = yield resource 
      LOGGING.debug "cnf_workload_resource yield resp: #{resp}"
      resp
    end
    resource_resp
  end

  #test_passes_completely = workload_resource_test do | cnf_config, resource, container, initialized |
  def self.workload_resource_test(args, config, 
                                  check_containers = true, 
                                  &block  : (NamedTuple(kind: YAML::Any, name: YAML::Any), 
                                             JSON::Any, JSON::Any, Bool | Nil) -> Bool | Nil)
            # resp = yield resource, container, volumes, initialized
    test_passed = true
    resource_ymls = cnf_workload_resources(args, config) do |resource|
      resource 
    end
    resource_names = Helm.workload_resource_kind_names(resource_ymls)
    LOGGING.info "resource names: #{resource_names}"
    if resource_names && resource_names.size > 0 
      initialized = true
    else
      LOGGING.error "no resource names found"
      initialized = false
    end
		resource_names.each do | resource |
			VERBOSE_LOGGING.debug resource.inspect if check_verbose(args)
      unless resource[:kind].as_s.downcase == "service" ## services have no containers
        containers = KubectlClient::Get.resource_containers(resource[:kind].as_s, resource[:name].as_s)
        volumes = KubectlClient::Get.resource_volumes(resource[:kind].as_s, resource[:name].as_s)
        if check_containers
          containers.as_a.each do |container|
            resp = yield resource, container, volumes, initialized
            LOGGING.debug "yield resp: #{resp}"
            # if any response is false, the test fails
            test_passed = false if resp == false
          end
        else
          resp = yield resource, containers, volumes, initialized
          LOGGING.debug "yield resp: #{resp}"
          # if any response is false, the test fails
          test_passed = false if resp == false
        end
      end
    end
    LOGGING.debug "workload resource test intialized: #{initialized} test_passed: #{test_passed}"
    initialized && test_passed
  end


  def self.final_cnf_results_yml
    LOGGING.info "final_cnf_results_yml" 
    results_file = `find ./results/* -name "cnf-conformance-results-*.yml"`.split("\n")[-2].gsub("./", "")
    if results_file.empty?
      raise "No cnf_conformance-results-*.yml found! Did you run the all task?"
    end
    results_file
  end

  def self.cnf_config_list(silent=false)
    LOGGING.info("cnf_config_list")
    LOGGING.info("find: find #{CNF_DIR}/* -name #{CONFIG_FILE}")
    cnf_conformance = `find #{CNF_DIR}/* -name "#{CONFIG_FILE}"`.split("\n").select{|x| x.empty? == false}
    LOGGING.info("find response: #{cnf_conformance}")
    if cnf_conformance.size == 0 && !silent
      raise "No cnf_conformance.yml found! Did you run the setup task?"
    end
    cnf_conformance
  end

  def self.destination_cnfs_exist?
    cnf_config_list(silent=true).size > 0
  end

  def self.parsed_config_file(path)
    if path.empty?
      raise "No cnf_conformance.yml found in #{path}!"
    end
    Totem.from_file "#{path}"
  end

  def self.sample_conformance_yml(sample_dir)
    LOGGING.info "sample_conformance_yml sample_dir: #{sample_dir}"
    cnf_conformance = `find #{sample_dir}/* -name "cnf-conformance.yml"`.split("\n")[0]
    if cnf_conformance.empty?
      raise "No cnf_conformance.yml found in #{sample_dir}!"
    end
    Totem.from_file "./#{cnf_conformance}"
  end

  def self.path_has_yml?(config_path)
    if config_path =~ /\.yml/  
      true
    else
      false
    end
  end

  def self.config_from_path_or_dir(cnf_path_or_dir)
    if path_has_yml?(cnf_path_or_dir)
      config_file = File.dirname(cnf_path_or_dir)
      config = sample_conformance_yml(config_file)
    else
      config_file = cnf_path_or_dir
      config = sample_conformance_yml(config_file)
    end
    return config
  end

  def self.ensure_cnf_conformance_yml_path(path : String)
    LOGGING.info("ensure_cnf_conformance_yml_path")
    if path_has_yml?(path)
      yml = path 
    else
      yml = path + "/cnf-conformance.yml" 
    end
  end

  def self.ensure_cnf_conformance_dir(path)
    LOGGING.info("ensure_cnf_conformance_yml_dir")
    if path_has_yml?(path)
      dir = File.dirname(path)
    else
      dir = path
    end
    dir + "/"
  end

  def self.release_name?(config)
    release_name = optional_key_as_string(config, "release_name").split(" ")[0]
    if release_name.empty?
      false
    else
      true
    end
  end

  def self.exclusive_install_method_tags?(config)
    installation_type_count = ["helm_chart", "helm_directory", "manifest_directory"].reduce(0) do |acc, install_type|
      begin
        test_tag = config[install_type]
        LOGGING.debug "install type count install_type: #{install_type}"
        if install_type.empty?
          acc
        else
          acc = acc + 1
        end
      rescue ex
        LOGGING.debug "install_type: #{install_type} not found in #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}"
        # LOGGING.debug ex.message
        # ex.backtrace.each do |x|
        #   LOGGING.debug x
        # end
        acc
      end
    end
    LOGGING.debug "installation_type_count: #{installation_type_count}"
    if installation_type_count > 1
      false
    else
      true
    end
  end

  #Determine, for cnf, whether a helm chart, helm directory, or manifest directory is being used for installation
  def self.cnf_installation_method(config)
    LOGGING.info "cnf_installation_method"
    LOGGING.info "cnf_installation_method config: #{config}"
    LOGGING.info "cnf_installation_method config: #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}"
    helm_chart = optional_key_as_string(config, "helm_chart")
    helm_directory = optional_key_as_string(config, "helm_directory")
    manifest_directory = optional_key_as_string(config, "manifest_directory")

    unless CNFManager.exclusive_install_method_tags?(config)
      puts "Error: Must populate at lease one installation type in #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}: choose either helm_chart, helm_directory, or manifest_directory in cnf-conformance.yml!".colorize(:red)
      raise "Error: Must populate at lease one installation type in #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}: choose either helm_chart, helm_directory, or manifest_directory in cnf-conformance.yml!"
    end
    if !helm_chart.empty?
      {:helm_chart, helm_chart}
    elsif !helm_directory.empty?
      {:helm_directory, helm_directory}
    elsif !manifest_directory.empty?
      {:manifest_directory, manifest_directory}
    else
      puts "Error: Must populate at lease one installation type in #{config.config_paths[0]}/#{config.config_name}.#{config.config_type}: choose either helm_chart, helm_directory, or manifest_directory.".colorize(:red)
      raise "Error in cnf-conformance.yml!"
    end
  end

  def self.helm_template_header(helm_chart_or_directory, template_file="/tmp/temp_template.yml")
    LOGGING.info "helm_template_header"
    helm = CNFSingleton.helm
    # generate helm chart release name
    # use --dry-run to generate yml file
    LOGGING.info("#{helm} install --dry-run --generate-name #{helm_chart_or_directory} > #{template_file}")
    helm_install = `#{helm} install --dry-run --generate-name #{helm_chart_or_directory} > #{template_file}`
    raw_template = File.read(template_file)
    split_template = raw_template.split("---")
    template_header = split_template[0]
    parsed_template_header = YAML.parse(template_header)
  end

  def self.helm_chart_template_release_name(helm_chart_or_directory, template_file="/tmp/temp_template.yml")
    LOGGING.info "helm_chart_template_release_name"
    hth = helm_template_header(helm_chart_or_directory, template_file)
    LOGGING.debug "helm template: #{hth}"
    hth["NAME"]
  end

  def self.generate_and_set_release_name(config_yml_path)
    LOGGING.info "generate_and_set_release_name"
    yml_file = CNFManager.ensure_cnf_conformance_yml_path(config_yml_path)
    yml_path = CNFManager.ensure_cnf_conformance_dir(config_yml_path)
    config = CNFManager.parsed_config_file(yml_file)

    predefined_release_name = optional_key_as_string(config, "release_name")
    LOGGING.debug "predefined_release_name: #{predefined_release_name}"
    if predefined_release_name.empty?
      install_method = self.cnf_installation_method(config)
      LOGGING.debug "install_method: #{install_method}"
      case install_method[0]
      when :helm_chart
        LOGGING.debug "helm_chart install method: #{install_method[1]}"
        release_name = helm_chart_template_release_name(install_method[1])
      when :helm_directory
        LOGGING.debug "helm_directory install method: #{yml_path}/#{install_method[1]}"
        release_name = helm_chart_template_release_name("#{yml_path}/#{install_method[1]}")
      when :manifest_directory
        LOGGING.debug "manifest_directory install method"
        release_name = UUID.random.to_s
      else 
        raise "Install method should be either helm_chart, helm_directory, or manifest_directory"
      end
      #set generated helm chart release name in yml file
      LOGGING.debug "generate_and_set_release_name: #{release_name}"
      update_yml(yml_file, "release_name", release_name)
    end
  end


  def self.cnf_destination_dir(config_file)
    LOGGING.info("cnf_destination_dir config_file: #{config_file}")
    if path_has_yml?(config_file)
      yml = config_file
    else
      yml = config_file + "/cnf-conformance.yml" 
    end
    config = parsed_config_file(yml)
    LOGGING.info "cnf_destination_dir parsed_config_file config: #{config}"
    current_dir = FileUtils.pwd 
    release_name = optional_key_as_string(config, "release_name").split(" ")[0]
    LOGGING.info "release_name: #{release_name}"
    LOGGING.info "cnf destination dir: #{current_dir}/#{CNF_DIR}/#{release_name}"
    "#{current_dir}/#{CNF_DIR}/#{release_name}"
  end

  def self.config_source_dir(config_file)
    if File.directory?(config_file)
      config_file
    else
      File.dirname(config_file)
    end
  end

  def self.helm_repo_add(helm_repo_name=nil, helm_repo_url=nil, args : Sam::Args=Sam::Args.new)
    LOGGING.info "helm_repo_add repo_name: #{helm_repo_name} repo_url: #{helm_repo_url} args: #{args.inspect}"
    ret = false
    if helm_repo_name == nil || helm_repo_url == nil
      # config = get_parsed_cnf_conformance_yml(args)
      # config = parsed_config_file(ensure_cnf_conformance_yml_path(args.named["cnf-config"].as(String)))
      config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_conformance_yml_path(args.named["cnf-config"].as(String)))    
      LOGGING.info "helm path: #{CNFSingleton.helm}"
      helm = CNFSingleton.helm
      # helm_repo_name = config.get("helm_repository.name").as_s?
      helm_repository = config.cnf_config[:helm_repository]
      helm_repo_name = "#{helm_repository && helm_repository["name"]}"
      helm_repo_url = "#{helm_repository && helm_repository["repo_url"]}"
      LOGGING.info "helm_repo_name: #{helm_repo_name}"
      # helm_repo_url = config.get("helm_repository.repo_url").as_s?
      LOGGING.info "helm_repo_url: #{helm_repo_url}"
    end
    if helm_repo_name && helm_repo_url
      ret = Helm.helm_repo_add(helm_repo_name, helm_repo_url)
    else
      ret = false
    end
    ret
  end

  def self.sample_setup_cli_args(args, noisy=true)
    VERBOSE_LOGGING.info "sample_setup_cli_args" if check_verbose(args)
    VERBOSE_LOGGING.debug "args = #{args.inspect}" if check_verbose(args)
    if args.named.keys.includes? "cnf-config"
      yml_file = args.named["cnf-config"].as(String)
      cnf_path = File.dirname(yml_file)
    elsif args.named.keys.includes? "cnf-path"
      cnf_path = args.named["cnf-path"].as(String)
    elsif noisy 
      stdout_failure "Error: You must supply either cnf-config or cnf-path"
      exit 1
    else
      cnf_path = ""
    end
    if args.named.keys.includes? "wait_count"
      wait_count = args.named["wait_count"].to_i
    elsif args.named.keys.includes? "wait-count"
      wait_count = args.named["wait-count"].to_i
    else
      wait_count = 180
    end
    {config_file: cnf_path, wait_count: wait_count, verbose: check_verbose(args)}
  end

  # Create a unique directory for the cnf that is to be installed under ./cnfs
  # Only copy the cnf's cnf-conformance.yml and it's helm_directory or manifest directory (if it exists)
  # Use manifest directory if helm directory empty
  def self.sandbox_setup(config, cli_args)
    LOGGING.info "sandbox_setup"
    LOGGING.info "sandbox_setup config: #{config.cnf_config}"
    verbose = cli_args[:verbose]
    config_file = config.cnf_config[:source_cnf_dir]
    release_name = config.cnf_config[:release_name]
    install_method = config.cnf_config[:install_method]
    helm_directory = config.cnf_config[:helm_directory]
    manifest_directory = config.cnf_config[:manifest_directory]
    helm_chart_path = config.cnf_config[:helm_chart_path]
    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)

    if install_method[0] == :manifest_directory
      manifest_or_helm_directory = config_source_dir(config_file) + "/" + manifest_directory 
    elsif !helm_directory.empty?
      manifest_or_helm_directory = config_source_dir(config_file) + "/" + helm_directory 
    else
      # this is not going to exist
      manifest_or_helm_directory = helm_chart_path #./cnfs/<cnf-release-name>/exported_chart
    end
      
    LOGGING.info("File.directory?(#{manifest_or_helm_directory}) #{File.directory?(manifest_or_helm_directory)}")
    # if the helm directory already exists, copy helm_directory contents into cnfs/<cnf-name>/<helm-directory-of-the-same-name>

    destination_chart_directory = {creation_type: :created, chart_directory: ""}
    if !manifest_or_helm_directory.empty? && manifest_or_helm_directory =~ /exported_chart/ 
      LOGGING.info "Ensuring exported helm directory is created"
      LOGGING.debug "mkdir_p destination_cnf_dir/exported_chart: #{manifest_or_helm_directory}"
      destination_chart_directory = {creation_type: :created,
                                     chart_directory: "#{manifest_or_helm_directory}"}
      FileUtils.mkdir_p(destination_chart_directory[:chart_directory]) 
    elsif !manifest_or_helm_directory.empty? && File.directory?(manifest_or_helm_directory) 
      # if !manifest_or_helm_directory.empty? && File.directory?(manifest_or_helm_directory) 
      LOGGING.info "Ensuring helm directory is copied"
      LOGGING.info("cp -a #{manifest_or_helm_directory} #{destination_cnf_dir}")
      destination_chart_directory = {creation_type: :copied,
                                     chart_directory: "#{manifest_or_helm_directory}"}
      yml_cp = `cp -a #{destination_chart_directory[:chart_directory]} #{destination_cnf_dir}`
      VERBOSE_LOGGING.info yml_cp if verbose
      raise "Copy of #{destination_chart_directory[:chart_directory]} to #{destination_cnf_dir} failed!" unless $?.success?
    end
    LOGGING.info "copy cnf-conformance.yml file"
    LOGGING.info("cp -a #{ensure_cnf_conformance_yml_path(config_file)} #{destination_cnf_dir}")
    yml_cp = `cp -a #{ensure_cnf_conformance_yml_path(config_file)} #{destination_cnf_dir}`
    destination_chart_directory
  end

  # Retrieve the helm chart source
  def self.export_published_chart(config, cli_args)
    verbose = cli_args[:verbose]
    config_file = config.cnf_config[:source_cnf_dir]
    helm_directory = config.cnf_config[:helm_directory]
    helm_chart = config.cnf_config[:helm_chart]
    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)

    current_dir = FileUtils.pwd 
    VERBOSE_LOGGING.info current_dir if verbose 

    helm = CNFSingleton.helm
    LOGGING.info "helm path: #{CNFSingleton.helm}"

    LOGGING.debug "mkdir_p destination_cnf_dir/helm_directory: #{destination_cnf_dir}/#{helm_directory}"
    #TODO don't think we need to make this here
    FileUtils.mkdir_p("#{destination_cnf_dir}/#{helm_directory}") 
    LOGGING.debug "helm command pull: #{helm} pull #{helm_chart}"
    #TODO move to helm module
    helm_pull = `#{helm} pull #{helm_chart}`
    VERBOSE_LOGGING.info helm_pull if verbose 
    # TODO helm_chart should be helm_chart_repo
    # TODO make this into a tar chart function
    VERBOSE_LOGGING.info "mv #{Helm.chart_name(helm_chart)}-*.tgz #{destination_cnf_dir}/exported_chart" if verbose
    core_mv = `mv #{Helm.chart_name(helm_chart)}-*.tgz #{destination_cnf_dir}/exported_chart`
    VERBOSE_LOGGING.info core_mv if verbose 

    VERBOSE_LOGGING.info "cd #{destination_cnf_dir}/exported_chart; tar -xvf #{destination_cnf_dir}/exported_chart/#{Helm.chart_name(helm_chart)}-*.tgz" if verbose
    tar = `cd #{destination_cnf_dir}/exported_chart; tar -xvf #{destination_cnf_dir}/exported_chart/#{Helm.chart_name(helm_chart)}-*.tgz`
    VERBOSE_LOGGING.info tar if verbose

    VERBOSE_LOGGING.info "mv #{destination_cnf_dir}/exported_chart/#{Helm.chart_name(helm_chart)}/* #{destination_cnf_dir}/exported_chart" if verbose
    move_chart = `mv #{destination_cnf_dir}/exported_chart/#{Helm.chart_name(helm_chart)}/* #{destination_cnf_dir}/exported_chart`
    VERBOSE_LOGGING.info move_chart if verbose
  ensure
    cd = `cd #{current_dir}`
    VERBOSE_LOGGING.info cd if verbose 
  end

  #sample_setup({config_file: cnf_path, wait_count: wait_count})
  def self.sample_setup(cli_args) 
    LOGGING.info "sample_setup cli_args: #{cli_args}"
    config_file = cli_args[:config_file]
    wait_count = cli_args[:wait_count]
    verbose = cli_args[:verbose]
    config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_conformance_yml_path(config_file))    
    release_name = config.cnf_config[:release_name]
    install_method = config.cnf_config[:install_method]

    #TODO add helm arguments to the cnf-conformance yml
    VERBOSE_LOGGING.info "sample_setup" if verbose
    LOGGING.info("config_file #{config_file}")

    config = CNFManager::Config.parse_config_yml(CNFManager.ensure_cnf_conformance_yml_path(config_file))    
    LOGGING.debug "config in sample_setup: #{config.cnf_config}"

    release_name = config.cnf_config[:release_name]
    install_method = config.cnf_config[:install_method]
    helm_directory = config.cnf_config[:helm_directory]
    manifest_directory = config.cnf_config[:manifest_directory]
    git_clone_url = config.cnf_config[:git_clone_url]
    helm_repository = config.cnf_config[:helm_repository]
    helm_repo_name = "#{helm_repository && helm_repository["name"]}"
    helm_repo_url = "#{helm_repository && helm_repository["repo_url"]}"
    LOGGING.info "helm_repo_name: #{helm_repo_name}"
    LOGGING.info "helm_repo_url: #{helm_repo_url}"

    helm_chart = config.cnf_config[:helm_chart]
    helm_chart_path = config.cnf_config[:helm_chart_path]
    LOGGING.debug "helm_directory: #{helm_directory}"

    #TODO move to sandbox module
    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)

    VERBOSE_LOGGING.info "destination_cnf_dir: #{destination_cnf_dir}" if verbose 
    LOGGING.debug "mkdir_p destination_cnf_dir: #{destination_cnf_dir}"
    FileUtils.mkdir_p(destination_cnf_dir) 

    # TODO enable recloning/fetching etc
    # TODO pass in block
    # TODO move to git module
    git_clone = `git clone #{git_clone_url} #{destination_cnf_dir}/#{release_name}`  if git_clone_url.empty? == false
    VERBOSE_LOGGING.info git_clone if verbose

    sandbox_setup(config, cli_args)

    helm = CNFSingleton.helm
    LOGGING.info "helm path: #{CNFSingleton.helm}"

    case install_method[0] 
    when :manifest_directory
      VERBOSE_LOGGING.info "deploying by manifest file" if verbose 
      #kubectl apply -f ./sample-cnfs/k8s-non-helm/manifests 
      # TODO move to kubectlclient
      # LOGGING.info("kubectl apply -f #{destination_cnf_dir}/#{manifest_directory}")
      # manifest_install = `kubectl apply -f #{destination_cnf_dir}/#{manifest_directory}`
      # VERBOSE_LOGGING.info manifest_install if verbose 
      KubectlClient::Apply.file("#{destination_cnf_dir}/#{manifest_directory}")

    when :helm_chart
      if !helm_repo_name.empty? || !helm_repo_url.empty?
        Helm.helm_repo_add(helm_repo_name, helm_repo_url)
      end
      VERBOSE_LOGGING.info "deploying with chart repository" if verbose 
      LOGGING.info "helm command: #{helm} install #{release_name} #{helm_chart}"
      #TODO move to Helm module
      helm_install = `#{helm} install #{release_name} #{helm_chart}`
      VERBOSE_LOGGING.info helm_install if verbose 
      export_published_chart(config, cli_args)
    when :helm_directory
      VERBOSE_LOGGING.info "deploying with helm directory" if verbose 
      #TODO Add helm options into cnf-conformance yml
      #e.g. helm install nsm --set insecure=true ./nsm/helm_chart
      LOGGING.info("#{helm} install #{release_name} #{destination_cnf_dir}/#{helm_directory}")
      #TODO move to helm module
      helm_install = `#{helm} install #{release_name} #{destination_cnf_dir}/#{helm_directory}`
      VERBOSE_LOGGING.info helm_install if verbose 
    else
      raise "Deployment method not found"
    end

    resource_ymls = cnf_workload_resources(nil, config) do |resource|
      resource 
    end
    resource_names = Helm.workload_resource_kind_names(resource_ymls)
    #TODO move to kubectlclient and make resource_install_and_wait_for_all function
    resource_names.each do | resource |
      case resource[:kind].as_s.downcase 
      when "replicaset", "deployment", "statefulset", "pod", "daemonset"
        # wait_for_install(resource_name, wait_count)
        KubectlClient::Get.resource_wait_for_install(resource[:kind].as_s, resource[:name].as_s, wait_count)
      end
    end
    if helm_install.to_s.size > 0 # && helm_pull.to_s.size > 0
      LOGGING.info "Successfully setup #{release_name}".colorize(:green)
    end
  end

  def self.sample_cleanup(config_file, force=false, installed_from_manifest=false, verbose=true)
    LOGGING.info "sample_cleanup"
    destination_cnf_dir = CNFManager.cnf_destination_dir(config_file)
    config = parsed_config_file(ensure_cnf_conformance_yml_path(config_file))

    VERBOSE_LOGGING.info "cleanup config: #{config.inspect}" if verbose
    release_name = "#{config.get("release_name").as_s?}"
    manifest_directory = destination_cnf_dir + "/" + "#{config["manifest_directory"]? && config["manifest_directory"].as_s?}"

    LOGGING.info "helm path: #{CNFSingleton.helm}"
    helm = CNFSingleton.helm
    dir_exists = File.directory?(destination_cnf_dir)
    ret = true
    LOGGING.info("destination_cnf_dir: #{destination_cnf_dir}")
    if dir_exists || force == true
      if installed_from_manifest
        # LOGGING.info "kubectl delete command: kubectl delete -f #{manifest_directory}"
        # kubectl_delete = `kubectl delete -f #{manifest_directory}`
        # ret = $?.success?
        ret = KubectlClient::Delete.file("#{manifest_directory}")
        # VERBOSE_LOGGING.info kubectl_delete if verbose
        # TODO put more safety around this
        rm = `rm -rf #{destination_cnf_dir}`
        VERBOSE_LOGGING.info rm if verbose
        if ret
          stdout_success "Successfully cleaned up #{manifest_directory} directory"
        end
      else
        LOGGING.info "helm uninstall command: #{helm} uninstall #{release_name.split(" ")[0]}"
        #TODO add capability to add helm options for uninstall
        helm_uninstall = `#{helm} uninstall #{release_name.split(" ")[0]}`
        ret = $?.success?
        VERBOSE_LOGGING.info helm_uninstall if verbose
        rm = `rm -rf #{destination_cnf_dir}`
        VERBOSE_LOGGING.info rm if verbose
        if ret
          stdout_success "Successfully cleaned up #{release_name.split(" ")[0]}"
        end
      end
    end
    ret
  end

  # TODO: figure out how to check this recursively 
  #
  # def self.recursive_json_unmapped(hashy_thing): JSON::Any
  #   unmapped_stuff = hashy_thing.json_unmapped

  #   Hash(String, String).from_json(hashy_thing.to_json).each_key do |key|
  #     if hashy_thing.call(key).responds_to?(:json_unmapped)
  #       return unmapped_stuff[key] = recursive_json_unmapped(hashy_thing[key])
  #     end
  #   end

  #   unmapped_stuff
  # end

  # TODO: figure out recursively check for unmapped json and warn on that
  # https://github.com/Nicolab/crystal-validator#check
  def self.validate_cnf_conformance_yml(config)
    ccyt_validator = nil
    valid = true 

    begin
      ccyt_validator = CnfConformanceYmlType.from_json(config.settings.to_json)
    rescue ex
      valid = false
      LOGGING.error "✖ ERROR: cnf_conformance.yml field validation error.".colorize(:red)
      LOGGING.error " please check info in the the field name near the text 'CnfConformanceYmlType#' in the error below".colorize(:red)
      LOGGING.error ex.message
      ex.backtrace.each do |x|
        LOGGING.error x
      end
    end

    unmapped_keys_warning_msg = "WARNING: Unmapped cnf_conformance.yml keys. Please add them to the validator".colorize(:yellow)
    unmapped_subkeys_warning_msg = "WARNING: helm_repository is unset or has unmapped subkeys. Please update your cnf_conformance.yml".colorize(:yellow)


    if ccyt_validator && !ccyt_validator.try &.json_unmapped.empty?
      warning_output = [unmapped_keys_warning_msg] of String | Colorize::Object(String)
      warning_output.push(ccyt_validator.try &.json_unmapped.to_s)
      if warning_output.size > 1
        LOGGING.warn warning_output.join("\n")
      end
    end

    #TODO Differentiate between unmapped subkeys or unset top level key.
    if ccyt_validator && !ccyt_validator.try &.helm_repository.try &.json_unmapped.empty? 
      root = {} of String => (Hash(String, JSON::Any) | Nil)
      root["helm_repository"] = ccyt_validator.try &.helm_repository.try &.json_unmapped

      warning_output = [unmapped_subkeys_warning_msg] of String | Colorize::Object(String)
      warning_output.push(root.to_s)
      if warning_output.size > 1
        LOGGING.warn warning_output.join("\n")
      end
    end

    { valid, warning_output }
  end

end
