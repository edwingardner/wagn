class KmlRenderer
  define_view(:show) do
    xml = Builder::XmlMarkup.new
    xml.instruct! :xml, :version => "1.0"
    
    xml.kml do
      xml.Document do
        
        cardnames = User.as(:wagbot) do
          # Note: we use wagbot to find all the applicable cards, but not for the geocode or description cards
          # This is a workaround so that folks can have maps so long as their geocode cards are publicly viewable.
          # needs deeper redesign
          if Card::Search === card
            card.item_cards( :return=>:name, :limit=>1000, :_keyword=>params[:_keyword] )
            card.results
          else
            [card.name]
          end
        end

        cardnames.each do |cardname|
          geocard = Card.fetch("#{cardname}+*geocode", :skip_virtual => true)
          if geocard && geocard.ok?(:read)
            xml.Placemark do
              xml.name cardname
              if desc_card = Card.fetch("#{cardname}+*geodescription") and desc_card.ok? :read
                xml.description Renderer.new(desc_card).render_naked
              end
              xml.Point do
                # apparently the google API likes them in the opposite order for static maps.
                # since we don't have code in the static maps address, we store them that way.
                xml.coordinates geocard.content.split(',').reverse.join(',')
              end
            end
          end
        end
        
      end
    end
  end
end