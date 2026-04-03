#pragma once

namespace updates {
	struct UpdateCheckRes {
		bool is_latest = true; // assumption for fails
		std::string latest_tag;
		std::string latest_tag_url;
	};

	tl::expected<UpdateCheckRes, std::string> is_latest_version(bool include_beta = false);

	bool update_to_tag(
		const std::string& tag,
		const std::optional<std::function<void(const std::string& text, bool done)>>& progress_callback = {}
	);
	bool update_to_latest(
		bool include_beta = false,
		const std::optional<std::function<void(const std::string& text, bool done)>>& progress_callback = {}
	);
}
