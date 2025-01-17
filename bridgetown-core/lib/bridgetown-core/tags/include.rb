# frozen_string_literal: true

module Bridgetown
  module Tags
    class IncludeTag < Liquid::Tag
      class << self
        attr_accessor :deprecation_message_shown
      end

      VALID_SYNTAX = %r!
        ([\w-]+)\s*=\s*
        (?:"([^"\\]*(?:\\.[^"\\]*)*)"|'([^'\\]*(?:\\.[^'\\]*)*)'|([\w\.-]+))
      !x.freeze
      VARIABLE_SYNTAX = %r!
        (?<variable>[^{]*(\{\{\s*[\w\-\.]+\s*(\|.*)?\}\}[^\s{}]*)+)
        (?<params>.*)
      !mx.freeze

      FULL_VALID_SYNTAX = %r!\A\s*(?:#{VALID_SYNTAX}(?=\s|\z)\s*)*\z!.freeze
      VALID_FILENAME_CHARS = %r!^[\w/\.-]+$!.freeze
      INVALID_SEQUENCES = %r![./]{2,}!.freeze

      def initialize(tag_name, markup, tokens)
        super

        unless self.class.deprecation_message_shown
          Bridgetown.logger.warn "NOTICE: the {% include %} tag is deprecated and" \
                                 " will be removed in Bridgetown 1.0. You should" \
                                 " use the {% render %} tag instead."
          self.class.deprecation_message_shown = true
        end

        matched = markup.strip.match(VARIABLE_SYNTAX)
        if matched
          @file = matched["variable"].strip
          @params = matched["params"].strip
        else
          @file, @params = markup.strip.split(%r!\s+!, 2)
        end
        validate_params if @params
        @tag_name = tag_name
      end

      def syntax_example
        "{% #{@tag_name} file.ext param='value' param2='value' %}"
      end

      def parse_params(context)
        params = {}
        markup = @params

        while (match = VALID_SYNTAX.match(markup))
          markup = markup[match.end(0)..-1]

          value = if match[2]
                    match[2].gsub('\\"', '"')
                  elsif match[3]
                    match[3].gsub("\\'", "'")
                  elsif match[4]
                    context[match[4]]
                  end

          params[match[1]] = value
        end
        params
      end

      def validate_file_name(file)
        if INVALID_SEQUENCES.match?(file) || !VALID_FILENAME_CHARS.match?(file)
          raise ArgumentError, <<~MSG
            Invalid syntax for include tag. File contains invalid characters or sequences:

              #{file}

            Valid syntax:

              #{syntax_example}

          MSG
        end
      end

      def validate_params
        unless FULL_VALID_SYNTAX.match?(@params)
          raise ArgumentError, <<~MSG
            Invalid syntax for include tag:

            #{@params}

            Valid syntax:

            #{syntax_example}

          MSG
        end
      end

      # Grab file read opts in the context
      def file_read_opts(context)
        context.registers[:site].file_read_opts
      end

      # Render the variable if required
      def render_variable(context)
        Liquid::Template.parse(@file).render(context) if VARIABLE_SYNTAX.match?(@file)
      end

      def tag_includes_dirs(context)
        context.registers[:site].includes_load_paths.freeze
      end

      def locate_include_file(context, file)
        includes_dirs = tag_includes_dirs(context)
        includes_dirs.each do |dir|
          path = File.join(dir, file)
          return path if valid_include_file?(path, dir.to_s)
        end
        raise IOError, could_not_locate_message(file, includes_dirs)
      end

      def render(context)
        file = render_variable(context) || @file
        validate_file_name(file)

        path = locate_include_file(context, file)
        return unless path

        partial = load_cached_partial(path, context)

        context.stack do
          context["include"] = parse_params(context) if @params
          begin
            partial.render!(context)
          rescue Liquid::Error => e
            e.template_name = path
            e.markup_context = "included " if e.markup_context.nil?
            raise e
          end
        end
      end

      def load_cached_partial(path, context)
        context.registers[:cached_partials] ||= {}
        cached_partial = context.registers[:cached_partials]

        if cached_partial.key?(path)
          cached_partial[path]
        else
          unparsed_file = context.registers[:site]
            .liquid_renderer
            .file(path)
          begin
            cached_partial[path] = unparsed_file.parse(read_file(path, context))
          rescue Liquid::Error => e
            e.template_name = path
            e.markup_context = "included " if e.markup_context.nil?
            raise e
          end
        end
      end

      def valid_include_file?(path, _dir)
        File.file?(path)
      end

      def realpath_prefixed_with?(path, dir)
        File.exist?(path) && File.realpath(path).start_with?(dir)
      rescue StandardError
        false
      end

      # This method allows to modify the file content by inheriting from the class.
      def read_file(file, context)
        File.read(file, **file_read_opts(context))
      end

      private

      def could_not_locate_message(file, includes_dirs)
        "Could not locate the included file '#{file}' in any of #{includes_dirs}." \
          " Ensure it exists in one of those directories."
      end
    end

    class IncludeRelativeTag < IncludeTag
      def tag_includes_dirs(context)
        Array(page_path(context)).freeze
      end

      def page_path(context)
        if context.registers[:page].nil?
          context.registers[:site].source
        else
          site = context.registers[:site]
          page_payload = context.registers[:page]
          resource_path = \
            if page_payload["collection"].nil?
              page_payload["path"]
            else
              File.join(site.config["collections_dir"], page_payload["path"])
            end
          # rubocop:disable Performance/DeleteSuffix
          resource_path.sub!(%r!/#excerpt\z!, "")
          # rubocop:enable Performance/DeleteSuffix
          site.in_source_dir File.dirname(resource_path)
        end
      end
    end
  end
end

Liquid::Template.register_tag("include", Bridgetown::Tags::IncludeTag)
Liquid::Template.register_tag("include_relative", Bridgetown::Tags::IncludeRelativeTag)
