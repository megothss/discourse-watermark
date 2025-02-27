import Component from "@glimmer/component";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { schedule } from "@ember/runloop";
import { inject as service } from "@ember/service";
import Category from "discourse/models/category";
import { getComputedColor, getComputedFont } from "../helpers/computed-values";
import renderWatermarkDataURL from "../helpers/render-watermark";

export default class WatermarkBackground extends Component {
  @service appEvents;
  @service currentUser;
  @service router;
  @service siteSettings;

  REFRESH_EVENTS = [
    // render on every page chance
    "page:changed",
    // updates the watermark again if the header of the topic was updated
    // in case the category or tags were edited
    "header:update-topic"
  ];

  onlyInCategories = settings.only_in_categories
    .split("|")
    .filter((id) => id !== "")
    .map((v) => parseInt(v, 10));
  exceptInCategories = settings.except_in_categories
    .split("|")
    .filter((id) => id !== "")
    .map((v) => parseInt(v, 10));
  onlyInTags = settings.only_in_tags.split("|").filter((id) => id !== "");
  exceptInTags = settings.except_in_tags.split("|").filter((id) => id !== "");
  urlRegexps = settings.or_if_url_matches
    .split("|")
    .filter((id) => id !== "")
    .map((v) => new RegExp(v));
  scrollEnabled = !!settings.scroll_enabled;

  #domElement;

  constructor() {
    super(...arguments);
    this.REFRESH_EVENTS.forEach((eventName) =>
      this.appEvents.on(eventName, this, this.refreshWatermark)
    );
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.REFRESH_EVENTS.forEach((eventName) =>
      this.appEvents.off(eventName, this, this.refreshWatermark)
    );
  }

  get currentCategories() {
    const currentRoute = this.router.currentRoute;

    if (currentRoute === null) {
      return [];
    }

    let category = null;

    // topics
    if (
      currentRoute.name === "topic.fromParams" ||
      currentRoute.name === "topic.fromParamsNear"
    ) {
      category = Category.findById(currentRoute.parent.attributes.category_id);
    }

    // categories
    if (currentRoute.params.category_slug_path_with_id) {
      category = Category.findBySlugPathWithID(
        currentRoute.params.category_slug_path_with_id
      );
    }

    if (category) {
      const categories = [category.id];

      // just in case there is some discourse out there with more than two levels of categories
      do {
        categories.push(category.parent_category_id);
        category = category.parentCategory;
      } while (category && category.parentCategory);

      return categories.filter((id) => id != null);
    }

    return [];
  }

  get currentTags() {
    const currentRoute = this.router.currentRoute;

    if (currentRoute === null) {
      return [];
    }

    // topics
    if (
      currentRoute.name === "topic.fromParams" ||
      currentRoute.name === "topic.fromParamsNear"
    ) {
      return currentRoute.parent.attributes.tags;
    }

    // categories
    if (currentRoute.params.tag_id) {
      return [currentRoute.params.tag_id];
    }

    return [];
  }

  get shouldShowWatermark() {
    const router = this.router;

    // check if there something to be rendered in the first place
    if (
      !(
        settings.display_text.trim() !== "" ||
        settings.display_username ||
        settings.display_timestamp
      )
    ) {
      return false;
    }

    let showWatermark;

    // PR by pfaffman
    showWatermark = this.siteSettings.title.match(
      settings.if_site_title_matches
    );

    // watermark applied by categories
    if (
      showWatermark &&
      (this.onlyInCategories.length > 0 || this.exceptInCategories.length > 0)
    ) {
      const categories = this.currentCategories;

      const testOnlyCategories =
        this.onlyInCategories.length === 0 ||
        categories.find((id) => this.onlyInCategories.indexOf(id) > -1);
      const testExceptCategories =
        testOnlyCategories &&
        (this.exceptInCategories.length === 0 ||
          categories.every((id) => this.exceptInCategories.indexOf(id) === -1));
      showWatermark = testOnlyCategories && testExceptCategories;
    }

    // watermark applied by tags
    // note that the test will be additive (&&) to the categories filter
    if (
      showWatermark &&
      (this.onlyInTags.length > 0 || this.exceptInTags.length > 0)
    ) {
      const tags = this.currentTags;

      const testOnlyTags =
        this.onlyInTags.length === 0 ||
        tags.find((id) => this.onlyInTags.indexOf(id) > -1);
      const testExceptTags =
        testOnlyTags &&
        (this.exceptInTags.length === 0 ||
          tags.every((id) => this.exceptInTags.indexOf(id) === -1));
      showWatermark = testOnlyTags && testExceptTags;
    }

    for (const regex of this.urlRegexps) {
      showWatermark = showWatermark || regex.test(router.currentURL);
      if (showWatermark) {
        break;
      }
    }

    return showWatermark;
  }

  @action
  setDomElement(element) {
    this.#domElement = element;
  }

  @action
  refreshWatermark() {
    schedule("afterRender", () => {
      if (this.shouldShowWatermark) {
        this.renderWatermark();
        return;
      }

      this.clearWatermark();
    });
  }

  @action
  clearWatermark() {
    const watermarkDiv = this.#domElement;
    watermarkDiv.style.backgroundImage = "";
  }

  @action
  renderWatermark() {
    const watermarkDiv = this.#domElement;
    const canvas = document.createElement("canvas");

    // we will use the dom element to resolve the CSS color even if
    // the user specify a CSS variable
    const resolvedColor = getComputedColor(watermarkDiv, settings.color);

    // now we will use the same trick to resolve the fonts
    const resolvedTextFont = getComputedFont(
      watermarkDiv,
      settings.display_text_font
    );
    const resolvedUsernameFont = getComputedFont(
      watermarkDiv,
      settings.display_username_font
    );
    const resolvedTimestampFont = getComputedFont(
      watermarkDiv,
      settings.display_timestamp_font
    );

    const data = {
      username: settings.display_username ? this.currentUser?.username : null,
      timestamp: settings.display_timestamp
        ? moment().format(settings.display_timestamp_format)
        : null
    };

    const watermark = renderWatermarkDataURL(
      canvas,
      {
        ...settings,
        color: resolvedColor,
        display_text_font: resolvedTextFont,
        display_username_font: resolvedUsernameFont,
        display_timestamp_font: resolvedTimestampFont
      },
      data
    );

    if (!watermark) {
      this.clearWatermark();
      return;
    }

    const backgroundImage = `url(${watermark})`;
    if (watermarkDiv.style.backgroundImage !== backgroundImage) {
      watermarkDiv.style.backgroundImage = backgroundImage;
    }
  }

  <template>
    <div
      id="watermark-background"
      class={{if this.scrollEnabled "scroll" "fixed"}}
      {{didInsert this.setDomElement}}
    />
  </template>
}
