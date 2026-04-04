#pragma once

namespace gui {
	inline tl::expected<void, std::string> initialisation_res = tl::make_unexpected("Not initialised");

	inline bool to_render = true;

	inline bool dragging = false;

	void event_loop();
	int run();
}
