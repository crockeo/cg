const std = @import("std");
const c = @cImport({
    @cInclude("git2.h");
});

pub fn main() !void {
    try wrap_git_call(c.git_libgit2_init());
    defer _ = c.git_libgit2_shutdown();

    std.debug.print("Opening repo\n", .{});
    var repository: ?*c.git_repository = undefined;
    try wrap_git_call(c.git_repository_open(&repository, "./.git"));
    defer c.git_repository_free(repository);

    std.debug.print("Status list\n", .{});
    const opts: c.git_status_options = .{
        .flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED,
        .show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR,
        .version = c.GIT_STATUS_OPTIONS_VERSION,
    };
    var status_list: ?*c.git_status_list = undefined;
    try wrap_git_call(c.git_status_list_new(&status_list, repository, &opts));

    const status_list_entry_count = c.git_status_list_entrycount(status_list);
    std.debug.print("Printing {d} entries\n", .{status_list_entry_count});
    for (0..status_list_entry_count) |i| {
        const status_entry = c.git_status_byindex(status_list, i);
        std.debug.print("{s}\n", .{status_entry.*.head_to_index.*.new_file.path});
    }
}

fn wrap_git_call(error_code: c_int) !void {
    if (error_code >= 0) {
        return;
    }
    const git_error = c.git_error_last();
    std.debug.print("{s}\n", .{git_error.*.message});
    return error.GitError;
}
