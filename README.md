<div align="right">
  <a href="https://www.buymeacoffee.com/Hashino" target="_blank">
    <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
    alt="Buy Me A Coffee" style="height: 24px !important;width: 104px !important;" >
  </a>
</div>

# learning.nvim

learn the language features naturally as you use it

![demo][demo.gif]

## installation

lazy.nvim:
```lua
{
  "Hashino/learning.nvim",
  opts = {
      provider = {
        api_key = "", -- your API key. be careful updating it your
        dotfiles
        api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
        model = "", -- the model you want to use, should be specified in the docs of your provider
      },
  },
}
```

vim.pack:
```lua
vim.pack.add({ "https://github.com/Hashino/learning.nvim", })
require("doing").setup({
  provider = {
    api_key = "", -- your API key. be careful updating it your
    dotfiles
    api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
    model = "", -- the model you want to use, should be specified in the docs of your provider
  },
})
```

[see the source code for default options](https://github.com/Hashino/learning.nvim/blob/main/lua/learning/config.lua)
