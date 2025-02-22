class Work < ApplicationRecord
  extend FriendlyId
  friendly_id :slug_candidates, :use => [:slugged, :history]
  
  has_many :pages, -> { order 'position' }, :dependent => :destroy, :after_add => :update_statistic, :after_remove => :update_statistic
  belongs_to :owner, :class_name => 'User', :foreign_key => 'owner_user_id', optional: true

  belongs_to :next_untranscribed_page, foreign_key: 'next_untranscribed_page_id', class_name: "Page", optional: true
  has_many :untranscribed_pages, -> { needs_transcription }, class_name: "Page"

  belongs_to :collection, counter_cache: :works_count, optional: true
  has_many :deeds, -> { order 'created_at DESC' }, :dependent => :destroy
  has_one :ia_work, :dependent => :destroy
  has_one :sc_manifest, :dependent => :destroy
  has_one :work_statistic, :dependent => :destroy
  has_many :sections, -> { order 'position' }, :dependent => :destroy
  has_many :table_cells, :dependent => :destroy

  has_and_belongs_to_many :scribes, :class_name => 'User', :join_table => :transcribe_authorizations

  has_many :document_set_works
  has_many :document_sets, through: :document_set_works
  has_one :work_facet, :dependent => :destroy

  after_save :update_statistic
  after_save :update_next_untranscribed_pages

  after_destroy :cleanup_images

  after_create :alert_intercom

  validates :title, presence: true, length: { minimum: 3, maximum: 255 }
  validates :slug, uniqueness: { case_sensitive: true }
  validate :document_date_is_edtf

  mount_uploader :picture, PictureUploader

  scope :unrestricted, -> { where(restrict_scribes: false)}
  scope :restricted, -> { where(restrict_scribes: true)}
  scope :order_by_recent_activity, -> { joins(:deeds).reorder('deeds.created_at DESC').distinct }
  scope :order_by_recent_inactivity, -> { joins(:deeds).reorder('deeds.created_at ASC').distinct }
  scope :order_by_completed, -> { joins(:work_statistic).reorder('work_statistics.complete DESC')}
  scope :order_by_incomplete, -> { joins(:work_statistic).reorder('work_statistics.complete ASC')}
  scope :order_by_translation_completed, -> { joins(:work_statistic).reorder('work_statistics.translation_complete DESC')}
  scope :incomplete_transcription, -> { where(supports_translation: false).joins(:work_statistic).where.not(work_statistics: {complete: 100})}
  scope :incomplete_translation, -> { where(supports_translation: true).joins(:work_statistic).where.not(work_statistics: {translation_complete: 100})}

  scope :ocr_enabled, -> { where(ocr_correction: true) }
  scope :ocr_disabled, -> { where(ocr_correction: false) }
  after_commit :save_metadata, on: [:create, :update]

  module TitleStyle
    REPLACE = 'REPLACE'

    PAGE_ARABIC = "Page #{REPLACE}"
    PAGE_ROMAN = "Page #{REPLACE}"
    ENVELOPE = "Envelope (#{REPLACE})"
    COVER = 'Cover (#{REPLACE})'
    ENCLOSURE = 'Enclosure REPLACE'
    DEFAULT = PAGE_ARABIC

    def self.render(style, number)
      style.sub(REPLACE, number.to_s)
    end

    def self.style_from_prior_title(title)
      PAGE_ARABIC
    end
    def self.number_from_prior_title(style, title)
      regex_string = style.sub('REPLACE', "(\\d+)")
      md = title.match(/#{regex_string}/)

      if md
        md.captures.first
      else
        nil
      end
    end
  end

  def verbatim_transcription_plaintext
    self.pages.map { |page| page.verbatim_transcription_plaintext}.join("\n\n\n")
  end

  def verbatim_translation_plaintext
    self.pages.map { |page| page.verbatim_translation_plaintext}.join("\n\n\n")
  end

  def emended_transcription_plaintext
    self.pages.map { |page| page.emended_transcription_plaintext}.join("\n\n\n")
  end

  def emended_translation_plaintext
    self.pages.map { |page| page.emended_translation_plaintext}.join("\n\n\n")
  end

  def searchable_plaintext
    self.pages.map { |page| page.search_text}.join("\n\n\n")
  end

  def suggest_next_page_title
    if self.pages.count == 0
      TitleStyle::render(TitleStyle::DEFAULT, 1)
    else
      prior_title = self.pages.last.title
      style = TitleStyle::style_from_prior_title(prior_title)
      number = TitleStyle::number_from_prior_title(style, prior_title)

      next_number = number ? number.to_i + 1 : self.pages.count + 1

      TitleStyle::render(style, next_number)
    end
  end

  def revert
  end

  def articles
    Article.joins(:page_article_links).where(page_article_links: {page_id: self.pages.ids}).distinct
  end


  def document_date=(date_as_edtf)
    if date_as_edtf.respond_to? :to_edtf
      self[:document_date] = date_as_edtf.to_edtf
    else
      # the edtf-ruby gem has some gaps in coverage for e.g. seasons
      self[:document_date] = date_as_edtf.to_s
    end      
  end

  def document_date
    Date.edtf(self[:document_date])
  end

  def document_date_is_edtf
    if self[:document_date].present?
      if Date.edtf(self[:document_date]).nil?
        errors.add(:document_date, 'must be in EDTF format')
      end
    end
  end

  def update_deed_collection
    deeds.where.not(:collection_id => collection_id).update_all(:collection_id => collection_id)
  end

  # TODO make not awful
  def reviews
    my_reviews = []
    for page in self.pages
      for comment in page.comments
        my_reviews << comment if comment.comment_type == 'review'
      end
    end
    return my_reviews
  end

  # TODO make not awful (denormalize work_id, collection_id; use legitimate finds)
  def recent_annotations
    my_annotations = []
    for page in self.pages
      for comment in page.comments
        my_annotations << comment if comment.comment_type == 'annotation'
      end
    end
    my_annotations.sort! { |a,b| b.created_at <=> a.created_at }
    return my_annotations[0..9]
  end

  def update_statistic(changed_page=nil) #association callbacks pass the page being added/removed, but we don't care
    unless self.work_statistic
      self.work_statistic = WorkStatistic.new
    end
    self.work_statistic.recalculate
  end

  def set_transcription_conventions
    if self.transcription_conventions.present?
      self.transcription_conventions
    else
      self.collection.transcription_conventions
    end
  end

  def cleanup_images
    new_dir_name = File.join(Rails.root, "public", "images", "uploaded", self.id.to_s)
    if Dir.exist?(new_dir_name)
      Dir.glob(File.join(new_dir_name, "*")){|f| File.delete(f)}
      Dir.rmdir(new_dir_name)
    end
  end

  def completed
    if self.supports_translation == true
      self.work_statistic.translation_complete
    else
      self.work_statistic.complete
    end
  end

  def untranscribed?
    self.work_statistic.pct_transcribed == 0
  end

  def thumbnail
    if !self.picture.blank?
      self.picture_url(:thumb)
    else
      unless self.pages.count == 0
        if self.featured_page.nil?
          set_featured_page
        end
        featured_page = Page.find_by(id: self.featured_page)
        featured_page.thumbnail_url
      else
        return nil
      end
    end
  end

  def normalize_friendly_id(string)
    string = string.truncate(230, separator: ' ', omission: '')
    super.gsub('_', '-')
  end

  def slug_candidates
    if self.slug
      [:slug]
    else
      [
        :title,
        [:title, :id]
      ]
    end
  end

  def should_generate_new_friendly_id?
    slug_changed? || super
  end

  def set_featured_page
      num = (self.pages.count/3).round
      page = self.pages.offset(num).first
      self.update_columns(featured_page: page.id)
  end

  def field_based
    self.collection.field_based
  end

  def supports_indexing?
    collection.subjects_disabled == false
  end

  def update_next_untranscribed_pages
    set_next_untranscribed_page
    collection&.set_next_untranscribed_page

    unless document_sets.empty?
      document_sets.each do |ds|
        ds.set_next_untranscribed_page
      end
    end
  end

  def set_next_untranscribed_page
    next_page = untranscribed_pages.order("position ASC").first
    page_id = next_page.nil? ? nil : next_page.id
    update_columns(next_untranscribed_page_id: page_id)
  end

  def has_untranscribed_pages?
    next_untranscribed_page.present?
  end

  def alert_intercom
    if (defined? INTERCOM_ACCESS_TOKEN) && INTERCOM_ACCESS_TOKEN
      if self.owner.owner_works.count == 1
        intercom=Intercom::Client.new(token:INTERCOM_ACCESS_TOKEN)
        intercom.events.create(event_name: "first-upload", email: self.owner.email, created_at: Time.now.to_i)
      end
    end
  end

  def save_metadata
    # this is costly, so only execute if the relevant value has actually changed
    if self.original_metadata && self.original_metadata_previously_changed? # this is costly, so only 
      om = JSON.parse(self.original_metadata)
      om.each do |m|
        unless m['label'].blank?
          label = m['label']

          collection = self.collection

          unless self.collection.nil?
            mc = collection.metadata_coverages.build

            # check that record exist
            test = collection.metadata_coverages.where(key: label).first
            # increment count field if a record is returned
            if test
              test.count+= 1
              test.save
            else
              mc.key = label.to_sym
              mc.count = 1
              mc.save
              mc.create_facet_config(metadata_coverage_id: mc.collection_id)
            end
          end
        end
      end

      # now update the work_facet
      FacetConfig.update_facets(self)
    end
  end
end
