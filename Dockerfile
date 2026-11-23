FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl sudo vim \
    && curl -fsSL https://gh.io/copilot-install -o /tmp/copilot-install.sh \
    && bash /tmp/copilot-install.sh \
    && rm /tmp/copilot-install.sh \
    && useradd --create-home --shell /bin/bash dotfiles \
    && printf 'dotfiles ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/dotfiles \
    && chmod 0440 /etc/sudoers.d/dotfiles

WORKDIR /workspace
COPY --chown=dotfiles:dotfiles setup.sh .bashrc .vimrc ./
COPY --chown=dotfiles:dotfiles .vimrc /home/dotfiles/.vimrc
COPY --chown=dotfiles:dotfiles .vim/colors/gruvbox.vim ./.vim/colors/gruvbox.vim
COPY --chown=dotfiles:dotfiles .vim/colors/gruvbox.vim /home/dotfiles/.vim/colors/gruvbox.vim

USER dotfiles
CMD ["sleep", "infinity"]
