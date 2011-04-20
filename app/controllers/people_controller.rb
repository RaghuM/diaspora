#   Copyright (c) 2010, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

class PeopleController < ApplicationController
  before_filter :authenticate_user!, :except => [:show]
  before_filter :ensure_page, :only => :show

  respond_to :html
  respond_to :json, :only => [:index, :show]

  def index
    @aspect = :search
    params[:q] ||= params[:term] || ''

    if (params[:q][0] == 35 || params[:q][0] == '#') && params[:q].length > 1
      redirect_to "/tags/#{params[:q].gsub("#", "")}"
      return
    end

    limit = params[:limit] ? params[:limit].to_i : 15

    respond_to do |format|
      format.json do
        @people = Person.search(params[:q], current_user).limit(limit)
        render :json => @people
      end

      format.all do
        @people = Person.search(params[:q], current_user).paginate :page => params[:page], :per_page => limit
        @hashes = hashes_for_people(@people, @aspects)

        #only do it if it is an email address

        puts params[:q]

        if params[:q].try(:match, /.+@.+/)
          puts 'in here'
          webfinger(params[:q])
        end
      end
    end
  end

  def hashes_for_people people, aspects
    ids = people.map{|p| p.id}
    contacts = {}
    Contact.unscoped.where(:user_id => current_user.id, :person_id => ids).each do |contact|
      contacts[contact.person_id] = contact
    end

    people.map{|p|
      {:person => p,
        :contact => contacts[p.id],
        :aspects => aspects}
    }
  end

  def show
    @person = Person.where(:id => params[:id]).first
    if @person && @person.remote? && !user_signed_in?
      render :file => "#{Rails.root}/public/404.html", :layout => false, :status => 404
      return
    end

    @post_type = :all
    @aspect = :profile
    @share_with = (params[:share_with] == 'true')

    if @person
      @profile = @person.profile

      if current_user
        @contact = current_user.contact_for(@person)
        @aspects_with_person = []
        if @contact && !params[:only_posts]
          @aspects_with_person = @contact.aspects
          @aspect_ids = @aspects_with_person.map(&:id)
          @contacts_of_contact = @contact.contacts

        else
          @contact ||= Contact.new
          @contacts_of_contact = []
        end

        if (@person != current_user.person) && !@contact.persisted?
          @commenting_disabled = true
        else
          @commenting_disabled = false
        end
        @posts = current_user.posts_from(@person).where(:type => "StatusMessage").includes(:comments).limit(15).offset(15*(params[:page]-1))

        Resque.enqueue(Job::RetrieveHistory, current_user.id, @person.id)

      else
        @commenting_disabled = true
        @posts = @person.posts.where(:type => "StatusMessage", :public => true).includes(:comments).limit(15).offset(15*(params[:page]-1))
      end


      @posts = PostsFake.new(@posts)
      if params[:only_posts]
        render :partial => 'shared/stream', :locals => {:posts => @posts}
      else
        respond_with @person, :locals => {:post_type => :all}
      end

    else
      flash[:error] = I18n.t 'people.show.does_not_exist'
      redirect_to people_path
    end
  end

  def retrieve_remote
    if params[:diaspora_handle]
      webfinger(params[:diaspora_handle], :single_aspect_form => true)
      render :nothing => true
    else
      render :nothing => true, :status => 422
    end
  end

  private
  def webfinger(account, opts = {})
    Resque.enqueue(Job::SocketWebfinger, current_user.id, account, opts)
  end
end
