require File.expand_path(File.dirname(__FILE__) + '/../../spec_helper')

describe Card do
  describe ".fetch" do
    it "returns and caches existing cards" do
      Card.fetch("A").should be_instance_of(Card::Basic)
      Card.cache.read("a").should be_instance_of(Card::Basic)
      Card.should_not_receive(:find_by_key)
      Card.fetch("A").should be_instance_of(Card::Basic)
    end

    it "returns nil and caches missing cards" do
      Card.fetch("Zork").should be_nil
      Card.cache.read("zork").missing.should be_true
      Card.fetch("Zork").should be_nil
    end

    it "returns nil and caches trash cards" do
      User.as(:wagbot)
      Card.fetch("A").destroy!
      Card.fetch("A").should be_nil
      Card.should_not_receive(:find_by_key)
      Card.fetch("A").should be_nil
    end

    it "returns and caches builtin cards" do
      Card.fetch("*head").should be_instance_of(Card::Basic)
      Card.cache.read("*head").should_not be_nil
    end

    it "returns virtual cards and caches them as missing" do
      User.as(:wagbot)
      card = Card.fetch("Joe User+*email")
      card.should be_instance_of(Card::Basic)
      card.name.should == "Joe User+*email"
      card.content.should == 'joe@user.com'
      cached_card = Card.cache.read("joe_user+*email")
      cached_card.missing?.should be_true
      cached_card.virtual?.should be_true
    end

    it "does not recurse infinitely on template templates" do
      Card.fetch("*content+*right+*content").should be_nil
    end

    it "expires card and dependencies on save" do
      #Card.cache.dump # should be empty
      Card.cache.reset_local
      Card.cache.local.keys.should == []

      User.as :wagbot

      a = Card.fetch("A")
      a.should be_instance_of(Card::Basic)

      # expires the saved card
      Card.cache.should_receive(:delete).with('a')

      # expires plus cards
      Card.cache.should_receive(:delete).with('c+a')
      Card.cache.should_receive(:delete).with('d+a')
      Card.cache.should_receive(:delete).with('f+a')
      Card.cache.should_receive(:delete).with('a+b')
      Card.cache.should_receive(:delete).with('a+c')
      Card.cache.should_receive(:delete).with('a+d')
      Card.cache.should_receive(:delete).with('a+e')
      Card.cache.should_receive(:delete).with('a+b+c')

      # expired including? cards
      Card.cache.should_receive(:delete).with('x').twice
      Card.cache.should_receive(:delete).with('y').twice
      a.save!
    end

    describe "preferences" do
      before do
        User.as :wagbot
      end

=begin
      it "prefers builtin virtual card to db cards" do
        Card.add_builtin(Card.new(:name => "ghost", :content => "Builtin Content"))
        Card.cache.read("ghost").virtual?.should be_true
        Card.create!(:name => "ghost", :content => "DB Content")
#        Card.cache.read("ghost").should be_nil
        card = Card.fetch("ghost")
        card.content.should == "Builtin Content"
        card.virtual?.should be_true
      end
=end

      it "prefers db cards to pattern virtual cards" do
        Card.create!(:name => "y+*right+*content", :content => "Formatted Content")
        Card.create!(:name => "a+y", :content => "DB Content")
        card = Card.fetch("a+y")
        card.virtual?.should be_false
        card.content.should == "DB Content"
        card.setting('content').should == "Formatted Content"
      end

      it "prefers a pattern virtual card to trash cards" do
        Card.create!(:name => "y+*right+*content", :content => "Formatted Content")
        Card.create!(:name => "a+y", :content => "DB Content")
        Card.fetch("a+y").destroy!

        card = Card.fetch("a+y")
        card.virtual?.should be_true
        card.content.should == "Formatted Content"
      end

      it "should not hit the database for every pattern_virtual lookup" do
        Card.create!(:name => "y+*right+*content", :content => "Formatted Content")
        Card.fetch("a+y")
        Card.should_not_receive(:find_by_key)
        Card.fetch("a+y")
      end
      
      it "should not be a new_record after being saved" do
        Card.create!(:name=>'growing up')
        card = Card.fetch('growing up')
        card.new_record?.should be_false
      end
    end
  end

  describe "#fetch_or_new" do
    it "returns a new card if it doesn't find one" do
      new_card = Card.fetch_or_new("Never Seen Me Before")
      new_card.should be_instance_of(Card::Basic)
      new_card.new_record?.should be_true
    end

    it "returns a card if it finds one" do
      new_card = Card.fetch_or_new("A+B")
      new_card.should be_instance_of(Card::Basic)
      new_card.new_record?.should be_false
    end

    it "takes a second hash of options as new card options" do
      new_card = Card.fetch_or_new("Never Before", {}, :type => "Image")
      new_card.should be_instance_of(Card::Image)
      new_card.new_record?.should be_true
    end
  end

  describe "#preload" do
    it "loads a list of cards into the cache" do
      a = Card.new(:name => "Appa")
      Card.preload([a])
      Card.should_not_receive(:find_by_key)
      Card.fetch("Appa").should == a
    end

    #it "with :local options loads a list of cards into the local cache only" do
    #  this test is meaningless as long as we have a nil store in testing env.
    #  a = Card.new(:name => "Appa")
    #  Card.cache.store.should_not_receive(:read)
    #  Card.cache.store.should_not_receive(:write)
    #  Card.preload([a], :local => true)
    #  Card.fetch("Appa").should == a
    #end
  end

  describe "#exists?" do
    it "is true for cards that are there" do
      Card.exists?("A").should == true
    end

    it "is false for cards that arent'" do
      Card.exists?("Mumblefunk is gone").should == false
    end
  end
end
