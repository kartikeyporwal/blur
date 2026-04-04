#pragma once

#include "config_blur.h"
#include "config_app.h"
#include "rendering.h"

class FrameRender {
	std::filesystem::path m_temp_path;
	bool m_to_kill = false;
	bool m_can_delete = false;

public:
	[[nodiscard]] bool can_delete() const {
		return m_can_delete;
	}

	void set_can_delete() {
		m_can_delete = true;
	}

	void stop() {
		m_to_kill = true;
	}

	tl::expected<void, std::string> do_render(RenderCommands render_commands, const BlurSettings& settings);

	bool create_temp_path();
	bool remove_temp_path();

	tl::expected<std::filesystem::path, std::string> render(
		const std::filesystem::path& input_path, const BlurSettings& settings, const GlobalAppSettings& app_settings
	);

	static tl::expected<RenderCommands, std::string> build_render_commands(
		const std::filesystem::path& input_path,
		const std::filesystem::path& output_path,
		const BlurSettings& settings,
		const GlobalAppSettings& app_settings
	);
};
