#require_dependency 'rich_html_renderer'
require_dependency 'models/wiki_reference'
require 'diff'

class Renderer
  module NoControllerHelpers
    def protect_against_forgery?
      # FIXME
      false
    end

    def logged_in?
      !(User.current_user.nil? || User.current_user.login == 'anon')
    end
  end

  include ReferenceTypes

  VIEW_ALIASES = {
    :view => :open,
    :card => :open,
    :line => :closed,
    :bare => :naked,
  }
  
  UNDENIABLE_VIEWS = [ 
    :deny_view, :edit_auto, :too_slow, :too_deep, :open_missing, :closed_missing, :setting_missing, :name, :link, :url
  ]

  RENDERERS = {
    :html => :RichHtml,
    :css  => :Text,
    :txt  => :Text
  }

  cattr_accessor :max_char_count, :max_depth, :set_views,
    :current_slot, :ajax_call, :fallback
  self.max_char_count = 200
  self.max_depth = 10

  attr_reader :action, :inclusion_map, :params, :layout, :relative_content,
      :template, :root, :format, :controller
  attr_accessor :card, :main_content, :main_card, :context, :char_count,
      :depth, :item_view, :form, :type, :base, :state, :sub_count,
      :render_args, :requested_view, :layout, :flash, :showname

  # View definitions
  #
  #   When you declare:
  #     define_view(:view_name, "<set>") do |args|
  #
  #   Methods are defined on the renderer
  #
  #   The external api with checks:
  #     render(:viewname, args)
  #
  #   Roughly equivalent to:
  #     render(_setname)_viewname(args)
  #
  #   The internal call that skips the checks:
  #     _render(_setname)_viewname(args)
  #  #
  class << self
    def alias_view(view, opts={}, *aliases)
      view_key = get_pattern(view, opts)
      aliases.each do |aview|
        case aview
        when String
        when Symbol
          aview_key = if view_key == view
              aview.to_sym
            else
              view_key.to_s.sub(/_#{view}$/, "_#{aview}").to_sym
            end
#Rails.logger.info("alias_view #{aview_key}, #{view} > #{aview}")
        when Hash
          aview_key = get_pattern(aview[:view]||view, aview)
        else raise "Bad view #{aview.inspect}"
        end

#Rails.logger.debug "defining aliased view #{view} #{aview.inspect} > #{aview_key}"
        class_eval do
          define_method( "_final_#{aview_key}".to_sym ) do
            Rails.logger.debug "ALIAS call: #{aview_key} called, calling #{view_key}"
            send("_final_#{view_key}")
          end
        end

        #register_view(view_key, aview_key)
#Rails.logger.debug "reg_alias(#{view_key}, #{view}) > #{aview.inspect} :: #{aview_key}"
      end
    end

    def define_view(view, opts={}, &final)
      fallback[view] = opts.delete(:fallback) if opts.has_key?(:fallback)
      view_key = get_pattern(view, opts)
      class_eval do
        define_method( "_final_#{view_key}", &final )
        #register_view(view_key, view_key)
#Rails.logger.debug "reg_view(_final_#{view_key}, #{view.inspect})"

        if view_key == view
#Rails.logger.debug "define base view: _render_#{view}, render_#{view}"
          define_method( "_render_#{view}" ) do |*a| a = [{}] if a.empty?
            final_meth = view_method( view )
#Rails.logger.debug " in #{caller(0).first}[#{card}] #{view}, #{final_meth}"
raise "??? #{view.inspect}" unless final_meth
            send(final_meth, *a) { yield }
          end

          define_method( "render_#{view}" ) do |*a|
            if refusal=render_check(view, *a); return refusal end
raise "no method #{method_id}, #{view}: #{@@set_views.inspect}" unless view_method( view )
            send( "_render_#{view}", *a) { yield }
          end
        end
      end
    end

    def get_pattern(view,opts)
      unless pkey =  Wagn::Pattern.method_key(opts) #and opts.empty?
        raise "Bad Pattern opts: #{pkey.inspect} #{opts.inspect}"
      end
      return (pkey.blank? ? view : "#{pkey}_#{view}").to_sym
    end

    def register_view(view_key, nview_key)
      if @@set_views.has_key?(nview_key)
        raise "Attempt to redefine view: #{nview_key}, #{view_key}"
      end
      @@set_views[nview_key.to_sym] = "_final_#{view_key}".to_sym
    end

    @@set_views, @@fallback = {},{} unless @@set_views

    def new(card, opts={})
      if self==Renderer
        fmt = (opts[:format] ? opts[:format].to_sym : :html)
        renderer_name = (RENDERERS.has_key?(fmt) ? RENDERERS[fmt] : fmt.to_s.camelize).to_s + 'Renderer'
        if Object.const_defined?( renderer_name)
          return Object.const_get( renderer_name ).new(card, opts) 
        end
      end
      new_renderer = self.allocate
      new_renderer.send :initialize, card, opts
      new_renderer
    end

    def set_view(key) @@set_views[key.to_sym] end
    def view_aliases() VIEW_ALIASES end
  end


  # Fragment left over from controller, I think this is all handled ?
  #   for :xhr, render_show => :naked, :html render_show => :layout
  #   all other formats should be mapped (?? what about :kml => :show ?)
  #format == :xhr ? render(:action=>'show') : render(:text=>'', :layout=>true)

  def initialize(card, opts=nil)
    Renderer.current_slot ||= self unless(opts[:not_current])
    @card = card
    if opts
      [ :main_content, :main_card, :base, :action, :context, :template,
        :params, :relative_content, :format, :flash, :layout, :controller].
          map {|s| instance_variable_set "@#{s}", opts[s]}
    end
    inclusion_map( opts )

    @relative_content ||= {}
    @action ||= 'view'
    @format ||= :html
    
    #not sure these are necessary now that we're handling controller.  would prefer not to have to pass them in...    
    @params ||= {}
    @flash ||= {}
    
    @template ||= begin
      t = ActionView::Base.new( CardController.view_paths, {} )
      t.helpers.send :include, CardController.master_helper_module
      t.helpers.send :include, NoControllerHelpers
      t
    end
    @template.controller = @controller
    @sub_count = @char_count = 0
    @depth = 0
    @root = self
#    if layout == :xhr
#      @layout = 'none'
#    elsif @params && @params[:layout]
#      @layout = @params[:layout]
#    end
  end
  
  def session
    @controller ? @controller.session : {}
  end

  def ajax_call?() @@ajax_call end
  def outer_level?() @depth == 0 end

  def too_deep?() @depth >= max_depth end

  def subrenderer(subcard, ctx_base=nil)
    subcard = Card.fetch_or_new(subcard) if String===subcard
    self.sub_count += 1
    sub = self.clone
    sub.depth = @depth+1
    sub.item_view = sub.main_content = sub.main_card = sub.showname = nil
    sub.sub_count = sub.char_count = 0
    sub.context = "#{ctx_base||context}_#{sub_count}"
    sub.card = subcard
    sub
  end

  def inclusion_map(opts=nil)
    return @inclusion_map if @inclusion_map and not opts
    return @inclusion_map = self.class.view_aliases unless opts and
      (@inclusion_map = opts[:inclusion_view_overrides])
    self.class.view_aliases.each_pair do |known, canonical|
      if @inclusion_map.has_key?(canonical)
        @inclusion_map[known] = @inclusion_map[canonical]
      end
    end
    @inclusion_map
  end

  def process_content(content=nil, opts={})
    return content unless card
    content = card.content if content.blank?

#Rails.logger.debug "process_content(#{content}, #{card&&card.content}),  #{card&&card.name}"

    wiki_content = WikiContent.new(card, content, self, inclusion_map)
    update_references(wiki_content) if card.references_expired

    wiki_content.render! do |opts|
      expand_inclusion(opts) { yield }
    end
  end
  alias expand_inclusions process_content


  def render_check(action, args={})
    ch_action = case
      when too_deep?      ; :too_deep
      when !card          ; false
      when card.new_card? ; false # causes errors to check in current system.  
        #should remove this and add create check after we settingize permissions
      when [:edit, :edit_in_form, :multi_edit].member?(action)
        !card.ok?(:edit) and :deny_view #should be deny_edit
      else
        !card.ok?(:read) and :deny_view
      end
      ch_action and render(ch_action, args)
  end

  def render_deny(action, args={})
    case
    when UNDENIABLE_VIEWS.member?(action); return
    when card && card.new_record?;         return # need create check...
    else render_check action, args
    end
  end

  def canonicalize_view( view )
    (view and v=VIEW_ALIASES[view.to_sym]) ? v : view
  end



  def render(action=:view, args={})
raise "???" if Hash===action
    args[:home_view] ||= action
    self.render_args = args.clone
    denial = render_deny(action, args)
    return denial if denial

    action = canonicalize_view(action)
    @state ||= case action
      when :edit, :multi_edit; :edit
      when :closed; :line
      else :view
    end

#Rails.logger.debug "calling view method(#{action}) #{card.inspect}"
    result = 
      if render_meth = view_method(action)
#Rails.logger.debug "render(#{action}) #{render_meth}"
        send(render_meth, args) { yield }
      else
        "<strong>#{card.name} - unknown card view: '#{action}' M:#{render_meth.inspect}</strong>"
      end

    result << javascript_tag("setupLinksAndDoubleClicks();") if args[:add_javascript]
    result.strip
  rescue Exception=>e
    Rails.logger.debug "Error #{e.inspect} #{e.backtrace*"\n"}"
    raise e unless Card::PermissionDenied===e
    return "Permission error: #{e.message}"
  end

  def view_method(view)
    return "_final_#{view}" unless card
#Rails.logger.debug "method keys for #{card.name}: #{Wagn::Pattern.method_keys(card).inspect}"
    
    Wagn::Pattern.method_keys(card).each do |method_key|
      
      meth = "_final_"+(method_key.blank? ? "#{view}" : "#{method_key}_#{view}")
#Rails.logger.debug "view_method( #{method_key} )  #{meth}"
      return meth if respond_to?(meth.to_sym)
    end
    return @@fallback[view]
  end
  
  def form_for_multi
    #Rails.logger.debug "card = #{card.inspect}"
    options = {} # do I need any? #args.last.is_a?(Hash) ? args.pop : {}
    block = Proc.new {}
    builder = options[:builder] || ActionView::Base.default_form_builder
    card.name.gsub!(/^#{Regexp.escape(root.card.name)}\+/, '+') if root.card.new_record?  ##FIXME -- need to match other relative inclusions.
    fields_for = builder.new("cards[#{card.name.pre_cgi}]", card, template, options, block)
  end

  def form
    @form ||= form_for_multi
  end

  def resize_image_content(content, size)
    size = (size.to_s == "full" ? "" : "_#{size}")
    content.gsub(/_medium(\.\w+\")/,"#{size}"+'\1')
  end

  def render_partial( partial, locals={} )
    template.render(:partial=>partial, :locals=>{ :card=>card, :slot=>self }.merge(locals))
  end

  def render_view_action(action, locals={})
    render_partial "views/#{action}", locals
  end

  def method_missing(method_id, *args, &proc)
    Rails.logger.debug "method missing: #{method_id}"
    # silence Rails 2.2.2 warning about binding argument to concat.  tried detecting rails 2.2
    # and removing the argument but it broken lots of integration tests.
    ActiveSupport::Deprecation.silence { @template.send(method_id, *args, &proc) }
  end

  def replace_references( old_name, new_name )
    #warn "replacing references...card name: #{card.name}, old name: #{old_name}, new_name: #{new_name}"
    wiki_content = WikiContent.new(card, card.content, self)

    wiki_content.find_chunks(Chunk::Link).each do |chunk|
      link_bound = chunk.card_name == chunk.link_text
      chunk.card_name.replace chunk.card_name.replace_part(old_name, new_name)
      chunk.link_text = chunk.card_name if link_bound
    end

    wiki_content.find_chunks(Chunk::Transclude).each do |chunk|
      chunk.card_name.replace chunk.card_name.replace_part(old_name, new_name)
    end

    String.new wiki_content.unrender!
  end

  def expand_inclusion(options)
    return options[:comment] if options.has_key?(:comment)
    # Don't bother processing inclusion if we're already out of view
    return '' if (state==:line && self.char_count > Renderer.max_char_count)

    tname=options[:tname]
    if is_main = tname=='_main'
      tcard, tcont = root.main_card, root.main_content
      return self.wrap_main(tcont) if tcont
      return "{{#{options[:unmask]}}}" || '{{_main}}' unless @depth == 0 and tcard

      tname = tcard.name
      [:item, :view, :size].each{ |key| val=symbolize_param(key) and options[key]=val }
      # main card uses these CGI options as inclusion args      
      options[:context] = 'main'
      options[:view] ||= :open
    end

    #Rails.logger.info " expanding.  view is currently: #{options[:view]}"

    options[:home_view] = options[:view] ||= context == 'layout_0' ? :naked : :content
    options[:fullname] = fullname = get_inclusion_fullname(tname,options)
    options[:showname] = tname.to_show(fullname)

    tcard ||= begin
      case
      when state ==:edit   ;  Card.fetch_or_new(fullname, {}, new_inclusion_card_args(tname, options))
      when base.respond_to?(:name);   base
      else                 ;  Card.fetch_or_new(fullname, :skip_defaults=>true)
      end
    end

    #Rails.logger.info " expanding card #{tcard.name}.  view is currently: #{options[:view]}"

    result = process_inclusion(tcard, options)
    result = resize_image_content(result, options[:size]) if options[:size]
    @char_count += (result ? result.length : 0) #should we strip html here?
    is_main ? self.wrap_main(result) : result
  rescue Card::PermissionDenied
    ''
  end

  def wrap_main(content)
    content  #no wrapping in base renderer
  end

  def symbolize_param(param)
    val = params[param]
    (val && !val.to_s.empty?) ? val.to_sym : nil
  end

  def resize_image_content(content, size)
    size = (size.to_s == "full" ? "" : "_#{size}")
    content.gsub(/_medium(\.\w+\")/,"#{size}"+'\1')
  end


  def process_inclusion(tcard, options)
    sub = subrenderer(tcard, options[:context])
    oldrenderer, Renderer.current_slot = Renderer.current_slot, sub
    sub.item_view = options[:item] if options[:item]
    sub.type = options[:type] if options[:type]
    sub.showname = options[:showname] || tcard.name

    new_card = tcard.new_record? && !tcard.virtual?

    vmode = options[:home_view] = (options[:view] || :content).to_sym
    sub.requested_view = vmode
    subview = case

      when [:name, :link, :linkname].member?(vmode)  ; vmode
      when :edit == state
       tcard.virtual? ? :edit_auto : :edit_in_form
      when new_card
        case
          when vmode==:raw    ; :blank
          when vmode==:setting; :setting_missing
          when state==:line   ; :closed_missing
          else                ; :open_missing
        end
      when state==:line       ; :closed_content
      else                    ; vmode
      end
    result = sub.render(subview, options)
    Renderer.current_slot = oldrenderer
    result
  rescue Exception=>e
    Rails.logger.info "inclusion-error #{e.inspect}"
    Rails.logger.debug "Trace:\n#{e.backtrace*"\n"}"
    %{<span class="inclusion-error">error rendering #{link_to_page((tcard ? tcard.name : 'unknown card'), nil, :title=>CGI.escapeHTML(e.inspect))}</span>}
  end

  def get_inclusion_fullname(name,options)
    fullname = name+'' #weird.  have to do this or the tname gets busted in the options hash!!
    context = case
    when base; (base.respond_to?(:name) ? base.name : base)
    when options[:base]=='parent'
      card.name.left_name
    else
      card.name
    end
    fullname = fullname.to_absolute(context)
    fullname = fullname.particle_names.map do |x|
      if x =~ /^_/ and params and params[x]
        CGI.escapeHTML( params[x] )
      else x end
    end.join("+")
    fullname
  end

  def get_inclusion_content(cardname)
    content = relative_content[cardname.gsub(/\+/,'_')]

    # CLEANME This is a hack to get it so plus cards re-populate on failed signups
    if relative_content['cards'] and card_params = relative_content['cards'][cardname.pre_cgi]
      content = card_params['content']
    end
    content if content.present?  #not sure I get why this is necessary - efm
  end

  def new_inclusion_card_args(tname, options)
    args = { :type =>options[:type],  :permissions=>[] }
    args[:loaded_trunk]=card if tname =~ /^\+/
    if content=get_inclusion_content(options[:tname])
      args[:content]=content
    end
    args
  end

  def update_references(rendering_result=nil)
    return unless card
    WikiReference.delete_all ['card_id = ?', card.id]

    if card.id
      card.connection.execute("update cards set references_expired=NULL where id=#{card.id}")
      rendering_result ||= WikiContent.new(card, _render_refs, self)
      rendering_result.find_chunks(Chunk::Reference).each do |chunk|
        reference_type =
          case chunk
            when Chunk::Link;       chunk.refcard ? LINK : WANTED_LINK
            when Chunk::Transclude; chunk.refcard ? TRANSCLUSION : WANTED_TRANSCLUSION
            else raise "Unknown chunk reference class #{chunk.class}"
          end

        WikiReference.create!( :card_id=>card.id,
          :referenced_name=>chunk.refcard_name.to_key,
          :referenced_card_id=> chunk.refcard ? chunk.refcard.id : nil,
          :link_type=>reference_type
         )
      end
    end
  end

  def paging_params
    if ajax_call? && @depth > 0
      {:default_limit=>20}  #important that paging calls not pass variables to included searches
    else
      @paging_params ||= begin
        s = {}
        if p = root.params
          [:offset,:limit,:_keyword].each{|key| s[key] = p.delete(key)}
        end
        s[:offset] = s[:offset] ? s[:offset].to_i : 0
        if s[:limit]
          s[:limit] = s[:limit].to_i
        else
          s.delete(:limit)
          s[:default_limit] = (main_card? ? 50 : 20) #can be overridden by card value
        end
        s
      end
    end
  end

  def main_card?() context=~/^main_\d$/ end
    
  def build_link(href, text)
    klass = case href
      when /^https?:/; 'external-link'
      when /^mailto:/; 'email-link'
      when /^\//
        href = full_uri(href)      
        'internal-link'
      else
        known_card = !!Card.fetch(href)
        text = text.to_show(href)
        href = '/wagn/' + (known_card ? href.to_url_key : CGI.escape(Cardname.escape(href)))
        href = full_uri(href)
        known_card ? 'known-card' : 'wanted-card'
    end
    %{<a class="#{klass}" href="#{href}">#{text}</a>}      
  end
  
  def full_uri(relative_uri)
    relative_uri
  end

  
end

class TextRenderer < Renderer
  def initialize card, opts
    super card,opts
    
    if format=='css' && controller
      controller.response.headers["Cache-Control"] = "public"
    end
  end
end

class KmlRenderer < Renderer
end

class RssRenderer < RichHtmlRenderer
  def full_uri(relative_uri)  System.base_url + relative_uri  end
end

class EmailHtmlRenderer < RichHtmlRenderer
  def full_uri(relative_uri)  System.base_url + relative_uri  end
end