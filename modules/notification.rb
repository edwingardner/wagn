module Notification   
  module CardMethods
    def send_notifications 
      action = case  
        when trash;  'deleted'
        when updated_at.to_s==created_at.to_s; 'added'
        when updated_at.to_s==current_revision.created_at.to_s;  'edited'  
        else; 'updated'
      end
      
      @trunk_watcher_watched_pairs = trunk_watcher_watched_pairs
      @trunk_watchers = @trunk_watcher_watched_pairs.map(&:first)
      
      watcher_watched_pairs.reject {|p| @trunk_watchers.include?(p.first) }.each do |watcher, watched|
        next unless watcher
        Mailer.deliver_change_notice( watcher, self, action, watched )
      end

      
      if nested_edit
        nested_edit.nested_notifications << [ name, action ]
      else
        @trunk_watcher_watched_pairs.compact.each do |watcher, watched|
          next unless watcher
          Mailer.deliver_change_notice( watcher, self.trunk, 'updated', watched, [[name, action]], self )
        end
      end
    end  
    
    def trunk_watcher_watched_pairs
      # do the watchers lookup before the transcluder test since it's faster.
      if (name.junction? and
          trunk_card = Card.fetch(name.trunk_name, :skip_virtual=>true) and
          pairs = trunk_card.watcher_watched_pairs and
          transcluders.include?(trunk))
        pairs
      else
        []
      end      
    end
    
    def self.included(base)   
      super                             
      base.class_eval do                
        attr_accessor :nested_edit, :nested_notifications
        after_save :send_notifications
      end
    end

    def watcher_watched_pairs
      author = User.current_user.card.name
      (card_watchers.except(author).map {|watcher| [Card.fetch(watcher, :skip_virtual=>true).extension,self.name] }  +
        type_watchers.except(author).map {|watcher| [Card.fetch(watcher, :skip_virtual=>true).extension,::Cardtype.name_for(self.type)]})
    end
    
    def card_watchers 
      items_from("#{name}+*watchers")
    end
    
    def type_watchers
      items_from(::Cardtype.name_for( self.type ) + "+*watchers" )
    end
    
    def items_from( cardname )
      User.as :wagbot do
        (c = Card.fetch(cardname, :skip_virtual=>true)) ? c.item_names.reject{|x|x==''} : []
      end
    end  
      
    def watchers
      card_watchers + type_watchers
    end
  end    

  module RendererHelperMethods
    def watch_link 
      return "" unless logged_in?   
      return "" if card.virtual? 
      me = User.current_user.card.name          
      if card.type == "Cardtype"
        (card.type_watchers.include?(me) ? "#{watching_type_cards} | " : "") +  watch_unwatch
      else
        if card.type_watchers.include?(me) 
          watching_type_cards
        else
          watch_unwatch
        end
      end
    end

    def watching_type_cards
      "watching #{link_to_page(Cardtype.name_for(card.type))} cards"      # can I parse this and get the link to happen? that wud r@wk.
    end

    def watch_unwatch      
      type_link = (card.type == "Cardtype") ? " #{card.name} cards" : ""
      type_msg = (card.type == "Cardtype") ? " cards" : ""    
      me = User.current_user.card.name   

      if card.card_watchers.include?(me) or card.type != 'Cardtype' && card.watchers.include?(me)
        link_to_action( "unwatch#{type_link}", 'unwatch', {:update=>id("watch-link")},{
   :title => "stop getting emails about changes to #{card.name}#{type_msg}"})
      else
       link_to_action( "watch#{type_link}", 'watch',
         {:update=>id("watch-link")},
         {:title=>"get emails about changes to #{card.name}#{type_msg}" } )
      end
    end
  end

  Wagn::Hook.add :before_multi_save, '*all' do |card, multi_card_params|
    multi_card_params.each_pair do |name, opts|
      opts[:nested_edit] = card
    end  
    card.nested_notifications = []
  end 

  Wagn::Hook.add :after_multi_update, '*all' do |card|
    if card.nested_notifications.present?  
      card.watcher_watched_pairs.each do |watcher, watched|
        Mailer.deliver_change_notice( watcher, card, 'updated', watched, card.nested_notifications )
      end
    end
  end
  
  def self.init
    Card::Base.send :include, CardMethods
    Renderer.send :include, RendererHelperMethods
  end   
end    

Notification.init



