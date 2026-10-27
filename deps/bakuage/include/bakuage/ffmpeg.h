#ifndef BAKUAGE_BAKUAGE_FFMPEG_H_
#define BAKUAGE_BAKUAGE_FFMPEG_H_

#include <boost/version.hpp>
#if BOOST_VERSION >= 108600
// Boost 1.86+ moved Process v1 under boost::process::v1; v2 is the default.
#include <boost/process/v1.hpp>
#else
#include <boost/process.hpp>
#endif
#include <stdexcept>
#include <string>
#include <vector>

namespace bakuage {
#if BOOST_VERSION >= 108600
namespace process_compat = boost::process::v1;
#else
namespace process_compat = boost::process;
#endif
class FFMpeg {
public:
    static void Execute(const std::string &ffmpeg_path, const std::string &input_filename,
                        const std::string &output_filename, const std::vector<std::string> &options) {
        // Resolve bare executable names through PATH without invoking a shell.
        boost::filesystem::path executable(ffmpeg_path);
        if (!executable.has_parent_path()) executable = process_compat::search_path(ffmpeg_path);
        if (executable.empty()) throw std::runtime_error("ffmpeg executable not found: " + ffmpeg_path);
        std::vector<std::string> args{"-nostdin", "-i", input_filename};
        args.insert(args.end(), options.begin(), options.end());
        // An absolute path cannot be interpreted as a command-line option.
        args.push_back(boost::filesystem::absolute(output_filename).string());
        process_compat::child process(executable, process_compat::args(args));
        process.wait();
        if (process.exit_code() != 0) {
            throw std::runtime_error("ffmpeg terminated with exit status: " + std::to_string(process.exit_code()));
        }
    }
};
}
#endif
