const Rule = @import("../rules.zig").Rule;

pub const rules = [_]Rule{
    .{
        .name = "huggingface-cache",
        .description = "Hugging Face model cache (can be very large)",
        .category = .ai,
        .risk = .moderate,
        .detection = .{ .path_prefix = "~/.cache/huggingface" },
    },
    .{
        .name = "ollama-models",
        .description = "Ollama LLM models",
        .category = .ai,
        .risk = .caution,
        .detection = .{ .path_prefix = "~/.ollama/models" },
    },
    .{
        .name = "torch-cache",
        .description = "PyTorch hub/model cache",
        .category = .ai,
        .risk = .moderate,
        .detection = .{ .path_prefix = "~/.cache/torch" },
    },
    .{
        .name = "keras-models",
        .description = "Keras model cache",
        .category = .ai,
        .risk = .moderate,
        .detection = .{ .path_prefix = "~/.keras/models" },
    },
    .{
        .name = "pipenv-venvs",
        .description = "Pipenv virtual environments",
        .category = .ai,
        .risk = .moderate,
        .detection = .{ .path_prefix = "~/.local/share/virtualenvs" },
    },
    .{
        .name = "conda-pkgs",
        .description = "Conda package cache",
        .category = .ai,
        .risk = .moderate,
        .detection = .{ .path_prefix = "~/.conda/pkgs" },
    },
};
