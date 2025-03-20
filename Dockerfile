FROM python:3.12.9-slim-bookworm as base

# Setup env
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONFAULTHANDLER 1
ENV PATH=/home/ftuser/.local/bin:$PATH
ENV FT_APP_ENV="docker"

# Declare additional build arguments for project dependencies
ARG AWS_ACCESS_KEY_ID
ARG AWS_SECRET_ACCESS_KEY
ARG AWS_DEFAULT_REGION

# Prepare environment
RUN mkdir /freqtrade \
  && apt-get update \
  && apt-get -y install sudo libatlas3-base curl sqlite3 libgomp1 \
  && apt-get clean \
  && useradd -u 1000 -G sudo -U -m -s /bin/bash ftuser \
  && chown -R ftuser:ftuser /freqtrade \
  # Allow sudoers
  && echo "ftuser ALL=(ALL) NOPASSWD: /bin/chown" >> /etc/sudoers

WORKDIR /freqtrade

# Install dependencies
FROM base as python-deps
RUN apt-get update \
  && apt-get -y install build-essential libssl-dev git libffi-dev libgfortran5 pkg-config cmake gcc \
  && apt-get clean \
  && pip install --upgrade pip wheel

# Install additional project dependencies
RUN apt-get update && apt-get install -y curl unzip awscli && \
    mkdir -p /freqtrade/user_data/ && \
    aws s3 cp s3://lab-settings/user_data/default.zip /freqtrade/user_data/default.zip \
        --endpoint-url https://fra1.digitaloceanspaces.com && \
    file /freqtrade/user_data/default.zip && \
    unzip -o /freqtrade/user_data/default.zip -d /freqtrade/user_data/ && \
    rm /freqtrade/user_data/default.zip

# Install custom strategies
RUN mkdir -p /freqtrade/user_data/strategies && \
    aws s3 cp s3://lab-settings/strategies/default.zip /freqtrade/user_data/strategies/default.zip \
        --endpoint-url https://fra1.digitaloceanspaces.com && \
    file /freqtrade/user_data/strategies/default.zip && \
    unzip -o /freqtrade/user_data/strategies/default.zip -d /freqtrade/user_data/strategies/ && \
    rm /freqtrade/user_data/strategies/default.zip

# Install TA-lib
COPY build_helpers/* /tmp/
RUN cd /tmp && /tmp/install_ta-lib.sh && rm -r /tmp/*ta-lib*
ENV LD_LIBRARY_PATH /usr/local/lib

# Install dependencies
COPY --chown=ftuser:ftuser requirements.txt requirements-hyperopt.txt requirements-freqai.txt requirements-freqai-rl.txt /freqtrade/
USER ftuser
RUN pip install --user --no-cache-dir "numpy<2.0" \
  && pip install --user --no-cache-dir -r requirements-hyperopt.txt \
  && pip install --user --no-cache-dir -r requirements-freqai-rl.txt \
  && pip install psycopg2-binary

# Copy dependencies to runtime-image
FROM base as runtime-image
COPY --from=python-deps /usr/local/lib /usr/local/lib
ENV LD_LIBRARY_PATH /usr/local/lib

COPY --from=python-deps --chown=ftuser:ftuser /home/ftuser/.local /home/ftuser/.local

# Copy user settings to runtime-image
COPY --from=python-deps --chown=ftuser:ftuser /freqtrade/user_data /freqtrade/user_data

USER ftuser
# Install and execute
COPY --chown=ftuser:ftuser . /freqtrade/

RUN pip install -e . --user --no-cache-dir --no-build-isolation \
  && freqtrade install-ui

ENTRYPOINT ["freqtrade"]
# Default to trade mode
CMD ["webserver", "--logfile", "/freqtrade/user_data/logs/freqtrade.log", "--config", "/freqtrade/user_data/config.json"]

