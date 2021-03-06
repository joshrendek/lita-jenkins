require 'json'
require 'base64'

module Lita
  module Handlers
    class Jenkins < Handler

      config :auth
      config :url
      config :http_options, required: false, type: Hash, default: {}

      route /j(?:enkins)? list( (.+))?/i, :jenkins_list, command: true, help: {
        'jenkins list <filter>' => 'lists Jenkins jobs'
      }

      route /j(?:enkins)? b(?:uild)? ([\w\.\-_ ]+)(, (.+))?/i, :jenkins_build, command: true, help: {
        'jenkins b(uild) <job_id or job_name>' => 'builds the job specified by ID or name. List jobs to get ID.'
      }

      def jenkins_build(response, empty_params = false)
        job = find_job(response.matches.last.first)
        input_params = response.matches.last.last

        unless job
          response.reply "I couldn't find that job. Try `jenkins list` to get a list."
          return
        end

        # Either a Hash of params or True/False
        params = input_params ? parse_params(input_params) : empty_params

        named_job_url = job_url(job['name'])
        path = job_build_url(job['url'], params)

        http_resp = http(config.http_options).post(path) do |req|
          req.headers = headers
          req.params  = params if params.is_a? Hash
        end

        if http_resp.status == 201
          reply_text = "(#{http_resp.status}) Build started for #{job['name']} #{named_job_url}"
          reply_text << ", Params: '#{input_params}'" if input_params
          response.reply reply_text
        elsif http_resp.status == 400
          log.debug 'Issuing rebuild with empty_params'
          jenkins_build(response, true)
        else
          response.reply http_resp.body
        end
      end

      def jenkins_list(response)
        filter = response.matches.first.last
        reply  = ''

        jobs.each_with_index do |job, i|
          job_name      = job['name']
          state         = color_to_state(job['color'])
          text_to_check = state + job_name

          reply << format_job(i, state, job_name) if filter_match(filter, text_to_check)
        end

        response.reply reply
      end

      def headers
        {}.tap do |headers|
          headers["Authorization"] = "Basic #{Base64.encode64(config.auth).chomp}" if config.auth
        end
      end

      def get_subjobs(job_url)
        api_response = http(config.http_options).get("#{job_url}api/json") do |req|
          req.headers = headers
        end
        ret = []
        JSON.parse(api_response.body)['jobs'].each do |job|
          ret << job if job.key?('color')
          ret << get_subjobs(job['url']) unless job.key?('color')
        end
        ret.flatten
      end

      def jobs
        api_response = http(config.http_options).get(api_url) do |req|
          req.headers = headers
        end
        job_arr = []
        resp = JSON.parse(api_response.body)["jobs"]
        resp.each do |job|
          job_arr << job if job.key?('color')
          job_arr << get_subjobs(job['url']) unless job.key?('color')
        end
        job_arr.flatten!
        job_arr
      end

      private

      def api_url
        "#{config.url}/api/json"
      end

      def job_url(job_name)
        "#{config.url}/job/#{job_name}"
      end

      def job_build_url(named_job_url, params)
        if params
          "#{named_job_url}/buildWithParameters?#{params}"
        else
          "#{named_job_url}/build"
        end
      end

      def find_job(requested_job)
        # Determine if job is only a number.
        if requested_job.match(/\A[-+]?\d+\z/)
          jobs[requested_job.to_i - 1]
        else
          jobs.select { |j| j['name'] == requested_job }.last
        end
      end

      def format_job(i, state, job_name)
        "[#{i + 1}] #{state} #{job_name}\n"
      end

      def color_to_state(text)
        case text
        when /disabled/
          'DISA'
        when /red/
          'FAIL'
        else
          'SUCC'
        end
      end

      def filter_match(filter, text)
        text.match(/#{filter}/i)
      end

      def parse_params(input_params)
        {}.tap do |params|
          input_params.split(',').each do |pair|
            key, value = pair.split(/=/)
            params[key.strip] = value.strip
          end
          log.debug "lita-jenkins#parse_params: #{params}"
        end
      end
    end

    Lita.register_handler(Jenkins)
  end
end
