# The web interface
# See site.defaults.yml for configuration.

require 'fileutils'
require 'yaml'
require 'multi_json'
require 'pathname'
require 'shellwords'
require 'net/http'
require 'uri'
require 'lockfile'
require 'logger'

class SandboxApp
  def self.debug_log # Dunno if Logger is safe to use in subprocesses, but don't care since it's a debug tool.
    @debug_log ||= Logger.new('/dev/null')
  end
  
  def self.debug_log=(new_logger)
    @debug_log = new_logger
  end
  
  
  module Paths
    extend Paths
    
    def web_dir
      Pathname.new(__FILE__).expand_path.parent
    end
    
    def work_dir
      web_dir + 'work'
    end
    
    def root_dir
      @@root_dir
    end
    
    def self.root_dir=(new_root_dir)
      @@root_dir = Pathname.new(new_root_dir).expand_path(web_dir)
    end
    
    def kernel_path
      root_dir + 'linux.uml'
    end
    
    def rootfs_path
      root_dir + 'rootfs.squashfs'
    end
    
    def initrd_path
      root_dir + 'initrd.img'
    end
    
    def output_tar_path
      work_dir + 'output.tar'
    end
    
    def vm_log_path
      work_dir + 'vm.log'
    end
  end
  
  
  class SubprocessWithTimeout
    def initialize(timeout, &block)
      @timeout = timeout
      @block = block
      
      @intermediate_pid = nil
    end
    
    # Runs block in an intermediate subprocess immediately after the main subprocess finishes or times out
    def when_done(&block)
      @after_block = block
    end
    
    def start
      raise 'previous run not waited nor killed' if @intermediate_pid
      
      @intermediate_pid = Process.fork do
        # We start a new session for two reasons.
        # First, we want to be able to kill the whole process group at once.
        # Second, UML likes to mess up the current session's console.
        #
        # Also, when UML panics, it goes berserk and kills its entire process group.
        # `wait` will then find this process dead by SIGTERM.
        #
        # Moreover we shall kill this entire process group if the UML timeouts too,
        # since otherwise UML child processes may be left, holding locks to files
        # and preventing future UMLs from starting.
        Process.setsid
        
        worker_pid = Process.fork(&@block)
        timeout_pid = Process.fork do
          [$stdin, $stdout, $stderr].each &:close
          sleep @timeout
        end
        SandboxApp.debug_log.debug "PIDS: Intermediate(#{Process.pid}), Worker(#{worker_pid}), Timeout(#{timeout_pid})"
        
        finished_pid, status = Process.waitpid2(-1)
        if finished_pid == worker_pid
          SandboxApp.debug_log.debug "Worker finished with status #{status.inspect}"
          Process.kill("KILL", timeout_pid)
          Process.waitpid(timeout_pid)
        else
          SandboxApp.debug_log.debug "Worker timed out. Will send notification and kill process group."
          status = :timeout
        end
        
        @after_block.call(status)
        Process.kill("KILL", -Process.pid) if status == :timeout
      end
    end
    
    def running?
      wait(false)
      @intermediate_pid != nil
    end
    
    def wait(block = true)
      if @intermediate_pid
        SandboxApp.debug_log.debug "Waiting for runner (#{@intermediate_pid}) to stop (blocking = #{block})"
        
        pid, status = Process.waitpid2(@intermediate_pid, if block then 0 else Process::WNOHANG end)
        if pid != nil
          SandboxApp.debug_log.debug "Runner (#{@intermediate_pid}) stopped. Status: #{status.inspect}."
          @intermediate_pid = nil
        end
      end
    end
    
    def kill
      if @intermediate_pid
        SandboxApp.debug_log.debug "Killing runner (#{@intermediate_pid}) process group"
        Process.kill("KILL", -@intermediate_pid) # kill entire process group
        wait
      end
    end
  end
  
  
  class Runner
    include Paths
    
    def initialize(settings)
      @settings = settings
      nuke_work_dir!
      
      @subprocess = SubprocessWithTimeout.new(@settings['timeout'].to_i) do
        $stdin.close
        $stdout.reopen("#{vm_log_path}", "w")
        $stderr.reopen($stdout)
        
        `dd if=/dev/zero of=#{output_tar_path} bs=#{@settings['max_output_size']} count=1`
        exit!(1) unless $?.success?
        
        cmd = Shellwords.join([
          "#{kernel_path}",
          "initrd=#{initrd_path}",
          "ubdarc=#{rootfs_path}",
          "ubdbr=#{@tar_file.path}",
          "ubdc=#{output_tar_path}",
          "mem=#{@settings['instance_ram']}",
          "con=null"
        ])
        
        SandboxApp.debug_log.debug "PID #{Process.pid} executing: #{cmd}"
        Process.exec(cmd)
      end
      
      @subprocess.when_done do |process_status|
        exit_code = nil
        status =
          if process_status == :timeout
            :timeout
          elsif process_status.success?
            begin
              exit_code = extract_file_from_tar(output_tar_path, 'exit_code.txt').to_i
            rescue
              SandboxApp.debug_log.warn "Failed to untar exit_code.txt"
              exit_code = nil
            end
            if exit_code == 0
              :finished
            else
              :failed
            end
          else
            SandboxApp.debug_log.warn "Sandbox failed with status #{process_status.inspect}"
            :failed
          end
        
        SandboxApp.debug_log.debug "Status: #{status}. Exit code: #{exit_code.inspect}."

        output = {
          'test_output' => try_extract_file_from_tar(output_tar_path, 'test_output.txt'),
          'stdout' => try_extract_file_from_tar(output_tar_path, 'stdout.txt'),
          'stderr' => try_extract_file_from_tar(output_tar_path, 'stderr.txt')
        }
        
        @notifier.send_notification(status, exit_code, output) if @notifier
      end
    end
    
    def start(tar_file, notifier)
      raise 'busy' if busy?
      
      nuke_work_dir!
      @tar_file = tar_file
      @notifier = notifier
      
      @subprocess.start
    end
    
    def busy?
      @subprocess.running?
    end
    
    def wait
      @subprocess.wait
    end
    
    def kill
      @subprocess.kill
    end
    
  private
    
    def nuke_work_dir!
      SandboxApp.debug_log.debug "Clearing work dir"
      FileUtils.rm_rf work_dir
      FileUtils.mkdir_p work_dir
    end

    def extract_file_from_tar(tar_path, file_name)
      result = `tar --to-stdout -xf #{output_tar_path} #{file_name} 2>/dev/null`
      raise "Failed to extract #{file_name} from #{tar_path}" if !$?.success?
      result
    end

    def try_extract_file_from_tar(tar_path, file_name)
      begin
        extract_file_from_tar(tar_path, file_name)
      rescue
        ""
      end
    end
  end
  
  
  class Notifier
    def initialize(url, token)
      @url = url
      @token = token
    end
    
    def send_notification(status, exit_code, output)
      postdata = output.merge({
        'token' => @token,
        'status' => status.to_s
      })
      postdata['exit_code'] = exit_code if exit_code != nil

      SandboxApp.debug_log.debug "Notifying #{@url}"
      resp = Net::HTTP.post_form(URI(@url), postdata)
    end
  end
end


class SandboxApp
  include SandboxApp::Paths

  class BadRequest < StandardError; end

  def initialize(settings_overrides = {})
    @settings = load_settings.merge(settings_overrides)
    SandboxApp.debug_log = Logger.new(@settings['debug_log_file']) unless @settings['debug_log_file'].to_s.empty?
    SandboxApp::Paths.root_dir = @settings['sandbox_files_root']
    init_check
    @runner = Runner.new(@settings)
  end

  def call(env)
    raw_response = nil
    Lockfile('lock') do
      @req = Rack::Request.new(env)
      @resp = Rack::Response.new
      @resp['Content-Type'] = 'application/json; charset=utf-8'
      @respdata = {}
      
      serve_request
      
      raw_response = @resp.finish do
        @resp.write(MultiJson.encode(@respdata))
      end
    end
    raw_response
  end
  
  def kill_runner
    @runner.kill
  end
  
  def wait_for_runner_to_finish
    @runner.wait
  end

private
  def serve_request
    begin
      if @req.post?
        serve_post_task
      else
        @resp.status = 404
        @respdata[:status] = 'not_found'
      end
    rescue BadRequest
      @respdata[:status] = 'bad_request'
      @resp.status = 500
    rescue
      @respdata[:status] = 'error'
      @resp.status = 500
    end
  end
  
  def serve_post_task
    if !@runner.busy?
      raise BadRequest.new('missing file parameter') if !@req['file'] || !@req['file'][:tempfile]
      notifier = if @req['notify'] then Notifier.new(@req['notify'], @req['token']) else nil end
      @runner.start(@req['file'][:tempfile], notifier)
      @respdata[:status] = 'ok'
    else
      @resp.status = 500
      @respdata[:status] = 'busy'
    end
  end
  
  def init_check
    raise 'kernel not compiled' unless File.exist? kernel_path
    raise 'rootfs not prepared' unless File.exist? rootfs_path
    raise 'initrd not made' unless File.exist? initrd_path
  end
  
  def load_settings
    settings = YAML.load_file(web_dir + 'site.defaults.yml')
    if File.exist?(web_dir + 'site.yml')
      settings = settings.merge(YAML.load_file(web_dir + 'site.yml'))
    end
    settings
  end
end

